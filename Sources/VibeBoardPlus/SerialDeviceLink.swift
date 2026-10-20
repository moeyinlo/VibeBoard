import Foundation

struct DeviceAudioFrame {
    let sessionID: UInt64
    let flags: UInt8
    var isLast: Bool { flags & 0x02 != 0 }
    let payload: Data

    static func parse(_ data: Data) -> Self? {
        guard data.count >= 16, data[0] == 1, data[1] == 1,
              UInt16(data[2]) | (UInt16(data[3]) << 8) == 16 else { return nil }
        let length = Int(data[14]) | (Int(data[15]) << 8)
        guard length <= SerialDeviceLink.maxFrameLen, data.count == 16 + length else { return nil }
        let sessionID = (0..<8).reduce(UInt64(0)) { $0 | (UInt64(data[4 + $1]) << ($1 * 8)) }
        return Self(sessionID: sessionID, flags: data[12],
                    payload: Data(data[16...]))
    }
}

/// 设备串口链路（ESP32 CDC ACM，/dev/cu.usbmodem*）——帧协议自原 App UsbCentral 逆向还原。
///
/// 帧格式（实测验证）：`[0x01][type][lenLo][lenHi][payload]`，type：0x01=音频帧、0x10=状态事件(JSON)、0x30=OTA 状态。
/// 握手：打开串口后发送 `{"event":"transport_ready","kind":"usb"}`（type 0x10），
/// 设备随即进入 USB mirror 模式并开始推送按键事件与音频帧。
final class SerialDeviceLink {
    static let frameTypeAudio: UInt8 = 0x01
    static let frameTypeState: UInt8 = 0x10
    static let frameTypeOTA: UInt8 = 0x30
    static let maxFrameLen = 4096
    static var rawLogCount = 0

    var onEvent: ((USBDeviceManager.DeviceEvent) -> Void)?
    var onRawData: ((Data) -> Void)?
    var onReady: (() -> Void)?
    var onDisconnect: (() -> Void)?

    private var fd: Int32 = -1
    private var reader: DispatchSourceRead?
    // Descriptor, parser, timers and callbacks all belong to the main queue.
    private let queue = DispatchQueue.main
    private(set) var isOpen = false
    private var pending = [UInt8]()
    private var heartbeatTimer: DispatchSourceTimer?

    func open(path: String) -> Bool {
        guard !isOpen else { return true }
        let fd = openDevice(path)
        guard fd >= 0 else { vlog("[serial] open failed path=\(path) errno=\(errno)"); return false }
        self.fd = fd
        isOpen = true
        pending.removeAll()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        // Close only after dispatch has stopped watching this descriptor.
        source.setCancelHandler { Darwin.close(fd) }
        reader = source
        source.resume()
        vlog("[serial] opened path=\(path)")
        runHandshake()
        return true
    }

    private func disconnected() {
        guard isOpen else { return }
        close()
        onDisconnect?()
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let available = reader?.data ?? 0
        for _ in 0..<64 {
            guard isOpen else { return }
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                pending.append(contentsOf: chunk.prefix(count))
                parseFrames()
            } else if count < 0 && errno == EINTR {
                continue
            } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                return
            } else if count == 0 && available > 0 {
                // VMIN=0 permits a zero-length read after draining the reported bytes.
                return
            } else {
                disconnected()
                return
            }
        }
    }

    /// 心跳：设备依赖周期 ping 判定主机在线（超时会主动断开 USB mirror）
    private func startHeartbeat() {
        heartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, self.isOpen else { return }
            self.sendFrame(type: Self.frameTypeState, body: Data("{\"event\":\"ping\"}".utf8))
        }
        timer.resume()
        heartbeatTimer = timer
    }

    func close() {
        isOpen = false
        handshakeGeneration += 1
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        deviceInfoTimer?.cancel()
        deviceInfoTimer = nil
        reader?.cancel()
        reader = nil
        fd = -1
        pending.removeAll()
        deviceInfoReceived = false
    }

    // MARK: - 发送

    func sendFrame(type: UInt8, body: Data) {
        guard fd >= 0 else { return }
        var frame = Data([0x01, type])
        frame.append(contentsOf: withUnsafeBytes(of: UInt16(body.count).littleEndian) { Data($0) })
        frame.append(body)
        frame.withUnsafeBytes { raw in
            _ = write(fd, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
    }

    /// 按键按下后主机回 ready（原 App："sending ready"，携带 session_id）
    func sendReady(sessionID: UInt64) {
        let body = Data("{\"event\":\"ready\",\"session_id\":\(sessionID)}".utf8)
        sendFrame(type: Self.frameTypeState, body: body)
    }

    /// 识别文本回传设备屏幕（原 App 字幕帧）
    func sendText(_ text: String) {
        sendUIState(.ready, text: text)
    }

    enum UIState: String { case recording, thinking, ready, error }

    static func uiStatePayload(_ state: UIState, text: String = "") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["event": "ui_state", "state": state.rawValue, "text": text])
    }

    func sendUIState(_ state: UIState, text: String = "") {
        if let data = try? Self.uiStatePayload(state, text: text) {
            vlog("[device-ui] state=\(state.rawValue) text_length=\(text.count)")
            sendFrame(type: Self.frameTypeState, body: data)
        }
    }

    func sendProvision(deviceID: String, secret: String) {
        let obj: [String: Any] = ["event": "provision", "device_id": deviceID, "device_secret": secret]
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            sendFrame(type: Self.frameTypeState, body: data)
        }
    }

    // MARK: - 接收与分帧

    private func parseFrames() {
        while true {
            // 对齐帧头：找 0x01
            guard let start = pending.firstIndex(where: { $0 == 0x01 }) else {
                if !pending.isEmpty {
                    // Unframed bytes are not valid device audio.
                    let data = Data(pending)
                    if isPrintableText(data) {
                        if let text = String(data: data, encoding: .utf8) {
                            checkDeviceReset(in: text)
                        }
                        onRawData?(data)
                    } else { diag("串口收到未封装数据：\(data.count)B，已忽略") }
                    pending.removeAll()
                }
                return
            }
            if start > 0 {
                onRawData?(Data(pending[0..<start]))
                pending.removeFirst(start)
            }
            guard pending.count >= 4 else { return }
            let type = pending[1]
            if type == Self.frameTypeAudio {
                // 音频帧：16 字节头，含 session ID、末帧标记和载荷长度。
                guard pending.count >= 16 else { return }
                guard pending[2] == 16, pending[3] == 0 else {
                    diag("无效音频帧头，重新同步")
                    pending.removeFirst(); continue
                }
                let payloadLen = Int(pending[14]) | (Int(pending[15]) << 8)
                guard payloadLen <= Self.maxFrameLen else {
                    onRawData?(Data(pending[0..<1])); pending.removeFirst(); continue
                }
                guard pending.count >= 16 + payloadLen else { return }
                let frame = DeviceAudioFrame.parse(Data(pending.prefix(16 + payloadLen)))
                pending.removeFirst(16 + payloadLen)
                if let frame { onEvent?(.audioFrame(frame)) }
            } else {
                // 状态/OTA 帧：4 字节头 [2..4]=u16 载荷长
                let len = Int(pending[2]) | (Int(pending[3]) << 8)
                guard len <= Self.maxFrameLen else {
                    onRawData?(Data(pending[0..<1])); pending.removeFirst(); continue
                }
                guard pending.count >= 4 + len else { return }
                let payload = Data(pending[4..<(4 + len)])
                pending.removeFirst(4 + len)
                dispatch(type: type, payload: payload)
            }
        }
    }

    private func isPrintableText(_ data: Data) -> Bool {
        guard let s = String(data: data, encoding: .utf8) else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0.isWhitespace || $0.isPunctuation || $0.isSymbol) }
    }

    private func dispatch(type: UInt8, payload: Data) {
        switch type {
        case Self.frameTypeAudio:
            diag("收到非标准音频载荷：\(payload.count)B，已忽略")
        case Self.frameTypeState:
            if let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                parse(event: obj)
            }
        default:
            onRawData?(payload)
        }
    }

    private func parse(event obj: [String: Any]) {
        let type = obj["event"] as? String ?? obj["type"] as? String
        let sessionID = obj["session_id"] as? UInt64 ?? 0
        let button = (obj["button"] as? String ?? "").lowercased()
        switch type {
        case "device_info":
            let firstResponse = !deviceInfoReceived
            if firstResponse { sendUIState(.ready) }
            deviceInfoReceived = true
            deviceInfoTimer?.cancel()  // 收到即停，避免高频轮询触发固件 spinlock 崩溃
            if firstResponse { vlog("[serial] device handshake confirmed"); onReady?() }
            if let data = try? JSONSerialization.data(withJSONObject: obj) {
                onRawData?(data)
            }
        case "button_down":
            onEvent?(.buttonDown(button: button, sessionID: sessionID))
        case "button_click":
            let dur = (obj["duration_ms"] as? Int) ?? 0
            onEvent?(.buttonClick(button: button, durationMS: dur))
        case "button_up":
            let duration = (obj["duration_ms"] as? Int) ?? 0
            onEvent?(.buttonUp(button: button, sessionID: sessionID, durationMS: duration))
        default:
            // device_info / provision_ack / device_error 等透传给上层日志
            if let data = try? JSONSerialization.data(withJSONObject: obj) {
                onRawData?(data)
            }
        }
    }

    /// 握手序列（可重放）：transport 激活 mirror → 0.5s 后 transport_ready + 心跳 + 轮询。
    /// 设备崩溃重启/超时断开后需要重新执行。
    private var handshakeGeneration = 0
    private func runHandshake() {
        handshakeGeneration += 1
        let generation = handshakeGeneration
        deviceInfoReceived = false
        sendFrame(type: Self.frameTypeState, body: Data("{\"event\":\"transport\",\"kind\":\"usb\"}".utf8))
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.isOpen, self.handshakeGeneration == generation else { return }
            self.sendFrame(type: Self.frameTypeState, body: Data("{\"event\":\"transport_ready\",\"kind\":\"usb\"}".utf8))
            self.startHeartbeat()
            self.startDeviceInfoPolling()
        }
        queue.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.isOpen, self.handshakeGeneration == generation, !self.deviceInfoReceived else { return }
            vlog("[serial] device handshake timed out")
            self.disconnected()
        }
    }

    /// 设备重启/断开检测：命中关键词后重放握手
    private func checkDeviceReset(in text: String) {
        if text.contains("Rebooting") || text.contains("host response timeout, disconnecting") {
            queue.async { [weak self] in
                guard let self, self.isOpen else { return }
                vlog("[VibeBoardPlus] device reset detected — replaying handshake")
                self.runHandshake()
            }
        }
    }

    /// 周期请求 device_info（原 App 行为：直到收到才停）
    private var deviceInfoReceived = false
    private var deviceInfoTimer: DispatchSourceTimer?
    private func startDeviceInfoPolling() {
        deviceInfoTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.isOpen, !self.deviceInfoReceived else { return }
            self.sendFrame(type: Self.frameTypeState, body: Data("{\"event\":\"get_device_info\"}".utf8))
        }
        timer.resume()
        deviceInfoTimer = timer
    }

    private func openDevice(_ path: String) -> Int32 {
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return -1 }
        var tty = termios()
        tcgetattr(fd, &tty)
        cfmakeraw(&tty)
        withUnsafeMutableBytes(of: &tty.c_cc) { ptr in
            ptr[Int(VMIN)] = 0
            ptr[Int(VTIME)] = 0
        }
        tcsetattr(fd, TCSANOW, &tty)
        var bits: Int32 = TIOCM_DTR | TIOCM_RTS
        ioctl(fd, TIOCMSET, &bits)
        return fd
    }
}
