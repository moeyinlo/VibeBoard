import Foundation
import Security

/// Keychain 存取（service 与原 App 一致：com.vibeboard.device-secret，account=deviceID）
enum KeychainStore {
    static func saveSecret(_ secret: String, deviceID: String) -> Bool {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.vibeboard.device-secret",
            kSecAttrAccount as String: deviceID,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func loadSecret(deviceID: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.vibeboard.device-secret",
            kSecAttrAccount as String: deviceID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// 编排：USB 设备 → 注册/配对 → token → ASR provider 选路。
///
/// ASR 选路策略（低延迟优先）：
/// 1. Apple Speech（本机识别，无网络往返）—— 默认首选
/// 2. Relay WebSocket（torchfun，设备 token 鉴权）—— 本机不可用时
/// 3. 备用远端（stepfun / bytedance / xiaozhi）—— relay 连续失败时
final class VibeBoardCoordinator {
    private let auth = DeviceAuthClient()
    private let usb = USBDeviceManager()
    private let serial = SerialDeviceLink()
    private let pipeline = ASRPipeline()
    private var relay: RelayASRClient?
    private let cloud = CloudASRProvider()
    private(set) var appleSpeech: AppleSpeechProvider?
    var onFinalText: ((String) -> Void)?
    var onPartialText: ((String) -> Void)?
    var onSessionStart: (() -> Void)?
    var onButtonAction: ((ButtonAction) -> Void)?
    var onRecognitionCancelled: (() -> Void)?
    let buttonSettings = ButtonSettings()
    private var buttonRouter = ButtonEventRouter()
    private var recordingButton: String?
    private var recordingSessionID: UInt64?
    private var sessionFrames = 0
    private var audioEndTimeout: DispatchWorkItem?
    var onStatus: ((String) -> Void)?

    private(set) var deviceID: String?
    private(set) var secret: String?

    /// 当前生效的 provider（文本来源）
    private(set) var activeProvider: ASRProvider?
    private var isActiveSessionRunning = false
    private var awaitingFinal = false
    private var finalTimeout: DispatchWorkItem?
    private var reconnectTimer: DispatchSourceTimer?

    func start() {
        cloud.onText = { [weak self] text, final in self?.pipeline.broadcastText(text, isFinal: final) }
        cloud.onError = { [weak self] message in
            guard let self, self.isActiveSessionRunning || self.awaitingFinal else { return }
            diag("识别错误：\(message)")
            self.completeRecognition("")
            self.onStatus?(message)
        }
        setupASRProviders()
        pipeline.onText = { [weak self] text, isFinal in
            vlog("[text\(isFinal ? " final" : "")] \(text)")
            // 原协议：识别文本回传设备屏幕显示，ui_state 才能从 recording/thinking 回到 ready
            if isFinal {
                DispatchQueue.main.async {
                    guard let self, self.isActiveSessionRunning || self.awaitingFinal else { return }
                    self.completeRecognition(text)
                }
            } else {
                DispatchQueue.main.async {
                    guard let self, self.isActiveSessionRunning || self.awaitingFinal else { return }
                    self.onPartialText?(text)
                }
            }
        }
        usb.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.handle(event: event) }
        }
        usb.start()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, self.usb.serialNumber != nil, !self.serial.isOpen else { return }
            self.openSerialLink()
        }
        timer.resume()
        reconnectTimer = timer
    }

    private func handle(event: USBDeviceManager.DeviceEvent) {
        switch event {
        case .attached(let info):
            onStatus?("发现设备，正在连接")
            vlog("[VibeBoardPlus] device attached mac=\(info.mac) hw=\(info.hardware)")
            openSerialLink()
            Task { @MainActor in await provision(device: info) }
        case .detached:
            buttonRouter = ButtonEventRouter()
            recordingButton = nil
            recordingSessionID = nil
            audioEndTimeout?.cancel(); audioEndTimeout = nil
            activeProvider?.stop()
            activeProvider = nil
            isActiveSessionRunning = false
            awaitingFinal = false
            finalTimeout?.cancel()
            serial.close()
            onStatus?("设备已断开")
        case .buttonDown(let button, let sessionID):
            diag("按下 \(button) session=\(sessionID) action=\(buttonSettings.action(for: button).rawValue)")
            let command = buttonRouter.down(button, session: sessionID, action: buttonSettings.action(for: button))
            executeButton(command, button: button)
        case .buttonUp(let button, let sessionID, _):
            diag("松开 \(button) session=\(sessionID)")
            executeButton(buttonRouter.up(button, now: ProcessInfo.processInfo.systemUptime), button: button)
        case .buttonClick(let button, let duration):
            diag("点击 \(button) duration=\(duration)ms")
            executeButton(buttonRouter.click(button, action: buttonSettings.action(for: button),
                                             now: ProcessInfo.processInfo.systemUptime), button: button)
        case .audioFrame(let frame):
            guard isActiveSessionRunning else { return }
            if let recordingSessionID, frame.sessionID != recordingSessionID {
                if frame.isLast { diag("忽略其他会话末帧 session=\(frame.sessionID)，当前=\(recordingSessionID)") }
                return
            }
            USBDeviceManager.audioCount += 1
            sessionFrames += 1
            if sessionFrames == 1 || sessionFrames % 50 == 0 || frame.isLast {
                diag("音频 #\(sessionFrames) session=\(frame.sessionID) bytes=\(frame.payload.count) flags=0x\(String(frame.flags, radix: 16)) last=\(frame.isLast)")
            }
            if !frame.payload.isEmpty { activeProvider?.sendAudio(frame.payload) }
            if frame.isLast { finishVoiceSession() }
        }
    }

    private func executeButton(_ command: ButtonEventRouter.Command?, button: String) {
        guard let command else { return }
        switch command {
        case .start(let session):
            guard !isActiveSessionRunning, !awaitingFinal else { return }
            recordingButton = button
            recordingSessionID = session == 0 ? nil : session
            serial.sendReady(sessionID: session)
            startVoiceSession()
        case .finish:
            guard recordingButton == button else { return }
            beginWaitingForAudioEnd()
        case .toggle(let session):
            if isActiveSessionRunning {
                guard recordingButton == button else { return }
                beginWaitingForAudioEnd()
            } else if !awaitingFinal {
                recordingButton = button
                recordingSessionID = session == 0 ? nil : session
                if session != 0 { serial.sendReady(sessionID: session) }
                startVoiceSession()
            }
        case .action(.cancel):
            activeProvider?.stop()
            audioEndTimeout?.cancel(); audioEndTimeout = nil
            finalTimeout?.cancel()
            isActiveSessionRunning = false
            awaitingFinal = false
            recordingButton = nil
            recordingSessionID = nil
            serial.sendUIState(.ready)
            onRecognitionCancelled?()
            onStatus?("已取消识别")
        case .action(let action):
            if !isActiveSessionRunning, !awaitingFinal { serial.sendUIState(.ready) }
            onButtonAction?(action)
        }
    }

    /// 读取原 App 配置中的 relay_api_key（stepfun 上游凭据）
    private static func loadRelayAPIKey() -> String? {
        let path = NSString("~/Library/Application Support/VibeBoard/config.toml").expandingTildeInPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("relay_api_key") {
                let value = trimmed.drop { $0 != "\"" }.dropFirst().dropLast()
                return value.isEmpty ? nil : String(value)
            }
        }
        return nil
    }

    /// 按键触发：优先本机 Apple Speech，不可用则走 Relay
    private func startVoiceSession() {
        guard !awaitingFinal else { return }
        guard !isActiveSessionRunning, let provider = selectProvider() else {
            diag("无法开始识别：provider=\(AppSettings().asrProvider) 未就绪")
            recordingButton = nil
            recordingSessionID = nil
            onStatus?("识别服务尚未就绪")
            serial.sendUIState(.ready)
            return
        }
        activeProvider = provider
        sessionFrames = 0
        isActiveSessionRunning = true
        diag("开始识别 button=\(recordingButton ?? "?") provider=\(provider.name) model=\(provider is CloudASRProvider ? AppSettings().asrModel : "local") session=\(recordingSessionID.map(String.init) ?? "unknown")")
        serial.sendUIState(.recording)
        onSessionStart?()
        onStatus?("正在聆听")
        provider.startSession()
    }

    private func beginWaitingForAudioEnd() {
        guard isActiveSessionRunning, audioEndTimeout == nil else { return }
        diag("按键已松开，等待设备音频末帧")
        serial.sendUIState(.thinking)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.isActiveSessionRunning else { return }
            diag("等待末帧超时，使用已收到的 \(self.sessionFrames) 帧结束识别")
            self.finishVoiceSession()
        }
        audioEndTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: timeout)
    }

    private func finishVoiceSession() {
        guard isActiveSessionRunning else { return }
        audioEndTimeout?.cancel(); audioEndTimeout = nil
        diag("结束音频输入：\(sessionFrames) 帧，等待转录结果")
        isActiveSessionRunning = false
        awaitingFinal = true
        serial.sendUIState(.thinking)
        onStatus?("正在生成识别结果")
        activeProvider?.finishSession()
        finalTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.awaitingFinal else { return }
            self.activeProvider?.stop()
            self.completeRecognition("")
            self.onStatus?("识别超时，请重试")
        }
        finalTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + (activeProvider is CloudASRProvider ? 60 : 12), execute: timeout)
    }

    private func completeRecognition(_ text: String) {
        audioEndTimeout?.cancel(); audioEndTimeout = nil
        finalTimeout?.cancel()
        finalTimeout = nil
        isActiveSessionRunning = false
        awaitingFinal = false
        diag("识别完成：\(text.count) 字符")
        recordingButton = nil
        recordingSessionID = nil
        serial.sendText(text)
        onFinalText?(text)
        if text.isEmpty { onStatus?("未识别到文字") }
    }

    private func selectProvider() -> ASRProvider? {
        switch AppSettings().asrProvider {
        case "stepfun": return cloud
        case "relay": return nil
        default: break
        }
        for candidate in pipeline.orderedProviders() {
            if let apple = candidate as? AppleSpeechProvider, apple.isAvailable {
                return apple
            }
        }
        return nil
    }

    /// 打开设备串口（CDC），事件与音频帧经同一入口分发
    private func openSerialLink() {
        guard !serial.isOpen else { return }
        guard let identity = usb.serialNumber, let path = SerialPortDiscovery.path(for: identity) else {
            onStatus?("等待设备串口，正在重试")
            return
        }
        serial.onReady = { [weak self] in
            guard let self else { return }
            self.onStatus?("设备已连接")
            if let deviceID = self.deviceID, let secret = self.secret {
                self.serial.sendProvision(deviceID: deviceID, secret: secret)
            }
        }
        serial.onDisconnect = { [weak self] in
            guard let self else { return }
            self.activeProvider?.stop()
            self.audioEndTimeout?.cancel(); self.audioEndTimeout = nil
            self.finalTimeout?.cancel()
            self.isActiveSessionRunning = false
            self.awaitingFinal = false
            self.recordingButton = nil
            self.recordingSessionID = nil
            self.buttonRouter = ButtonEventRouter()
            self.onRecognitionCancelled?()
            self.onStatus?("连接中断，正在重连")
        }
        serial.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.handle(event: event) }
        }
        serial.onRawData = { data in
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                vlog("[device] \(text)")
            } else {
                SerialDeviceLink.rawLogCount += 1
                if SerialDeviceLink.rawLogCount % 50 == 1 {
                    vlog("[audio?] \(data.count)B hex: \(data.prefix(32).map { String(format: "%02x", $0) }.joined())")
                }
            }
        }
        if serial.open(path: path) {
            vlog("[VibeBoardPlus] serial link opened")
        } else {
            vlog("[VibeBoardPlus] serial open failed")
            onStatus?("串口连接失败，正在重试")
        }
    }

    /// 注册 → 存 secret → 装配 ASR providers。失败由 USB 心跳自愈循环重入。
    private func provision(device info: USBDeviceManager.DeviceInfo) async {
        guard !info.mac.isEmpty else { return }
        vlog("[VibeBoardPlus] provisioning mac=\(info.mac)…")
        if deviceID == nil {
            do {
                let result = try await auth.registerDevice(mac: info.mac, hardware: info.hardware,
                                                           registrationToken: nil)
                deviceID = result.deviceID
                if let s = result.secret {
                    secret = s
                    KeychainStore.saveSecret(s, deviceID: result.deviceID)
                } else {
                    secret = KeychainStore.loadSecret(deviceID: result.deviceID)
                }
            } catch {
                vlog("[VibeBoardPlus] register failed: \(error)")
                return // 交给心跳循环重试
            }
            vlog("[VibeBoardPlus] registered deviceID=\(deviceID!) secret=\(secret != nil ? "yes" : "no")")
        }
        // 把注册凭据下发给设备（原协议 provision 流程）
        if let deviceID, let secret {
            serial.sendProvision(deviceID: deviceID, secret: secret)
        }
        setupASRProviders()
        // token 交换验证（Relay 鉴权前置条件）
        if let deviceID, let secret {
            do {
                _ = try await auth.validToken(deviceID: deviceID, secret: secret)
                vlog("[VibeBoardPlus] token OK")
            } catch {
                vlog("[VibeBoardPlus] token FAILED: \(error)")
            }
        }
        // Relay WS 握手验证
        if let client = relay {
            client.onStateChange = { st in
                vlog("[VibeBoardPlus] relay state: \(st.rawValue)")
            }
        }
    }

    private func setupASRProviders() {
        // 1) 本机识别：无网络往返，延迟最低
        if appleSpeech == nil, Bundle.main.bundleIdentifier != nil {
            let speech = AppleSpeechProvider(pipeline: pipeline)
            appleSpeech = speech
            pipeline.register(speech)
        }

        // 2) Relay + 远端备用
        if let deviceID, let secret, relay == nil {
            let client = RelayASRClient(
                options: .init(
                    relayURL: URL(string: "wss://torchfun.com/v1/voice")!,
                    apiKey: Self.loadRelayAPIKey()
                ),
                auth: auth,
                deviceIDProvider: { [weak self] in self?.deviceID },
                secretProvider: { [weak self] in self?.secret }
            )
            client.onText = { [weak self] text, isFinal in
                self?.pipeline.broadcastText(text, isFinal: isFinal)
            }
            relay = client
            pipeline.register(client)
        }
    }
}
