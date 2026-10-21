import AppKit
import Foundation
import Security
import CVibeBoardCore

/// Keychain storage for the device secret (service name kept from the pre-core client so
/// existing installations keep working).
enum KeychainStore {
    private static let service = "com.vibeboard.device-secret"

    static func saveSecret(_ secret: String, deviceID: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceID,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(secret.utf8)
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func loadSecret(deviceID: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
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

/// Diagnostics reported by the local Whisper engine.
struct LocalEngineStats {
    let backend: String
    let model: String
    let audioSeconds: Double
    let durationSeconds: Double
    let realtimeFactor: Double
    let threads: Int
    let peakRssMb: Double?
    let systemInfo: String

    var summary: String {
        let memory = peakRssMb.map { String(format: "%.0f MB", $0) } ?? "未知"
        return String(
            format: "%@ · %@ · 音频 %.1fs / 耗时 %.2fs（RTF %.2f） · 线程 %d · 峰值内存 %@",
            backend, model, audioSeconds, durationSeconds, realtimeFactor, threads, memory
        )
    }
}

struct LocalBackendInfo {
    let active: String
    let compiled: [String]
    let systemInfo: String
}

/// Process-wide status shared with the settings window.
final class EngineStatus {
    static let shared = EngineStatus()
    private(set) var backend: LocalBackendInfo?
    private(set) var lastStats: LocalEngineStats?
    var onChange: (() -> Void)?

    func updateBackend(_ info: LocalBackendInfo?) {
        backend = info
        DispatchQueue.main.async { self.onChange?() }
    }

    func updateStats(_ stats: LocalEngineStats) {
        lastStats = stats
        DispatchQueue.main.async { self.onChange?() }
    }
}

/// Owns the Rust core handle and translates between C callbacks and the AppKit UI.
final class CoreHost {
    private var handle: OpaquePointer?
    private let speech = AppleSpeechProvider()
    private let speechQueue = DispatchQueue(label: "app.vibeboardplus.apple-speech")
    private let buttons: ButtonSettings
    private var usesAppleSpeech = true

    var onStatus: ((String) -> Void)?
    var onPartialText: ((String) -> Void)?
    var onFinalText: ((String) -> Void)?
    var onSessionStart: (() -> Void)?
    var onCancelled: (() -> Void)?
    var onError: ((String) -> Void)?
    var onAction: ((ButtonAction) -> Void)?

    init(buttonSettings: ButtonSettings) {
        buttons = buttonSettings
    }

    var speechProvider: AppleSpeechProvider { speech }

    // MARK: - Lifecycle

    func start() {
        guard handle == nil else { return }
        // Route core logs into the app log before the core can emit anything.
        vb_set_log_callback(coreLog, Unmanaged.passUnretained(self).toOpaque())

        var callbacks = vb_callbacks()
        callbacks.userdata = Unmanaged.passUnretained(self).toOpaque()
        callbacks.on_status = coreStatus
        callbacks.on_partial_text = corePartial
        callbacks.on_final_text = coreFinal
        callbacks.on_error = coreError
        callbacks.on_action = coreAction
        callbacks.on_local_stats = coreStats
        callbacks.on_session_started = coreSessionStarted
        callbacks.on_cancelled = coreCancelled
        callbacks.on_pcm = corePcm
        callbacks.on_pcm_end = corePcmEnd
        callbacks.load_secret = coreLoadSecret
        callbacks.save_secret = coreSaveSecret

        var error: UnsafeMutablePointer<CChar>?
        let config = makeConfigJSON()
        handle = vb_core_new(config, callbacks, &error)
        if handle == nil {
            let message = error.map { String(cString: $0) } ?? "未知错误"
            if let error { vb_string_free(error) }
            vlog("[core] 初始化失败：\(message)")
            onError?("内核初始化失败：\(message)")
            return
        }

        speech.onText = { [weak self] text, final in
            guard let self, let handle = self.handle else { return }
            text.withCString { pointer in
                vb_core_external_text(handle, pointer, final ? 1 : 0)
            }
            if final { self.speechQueue.async { self.speech.reset() } }
        }

        vlog("[core] 内核 v\(CoreHost.version()) 已加载")
        if let info = CoreHost.backendInfo() {
            vlog("[core] 本地引擎：\(info.active)（\(info.compiled.joined(separator: "/"))）")
            EngineStatus.shared.updateBackend(info)
        } else {
            EngineStatus.shared.updateBackend(nil)
        }

        let result = vb_core_start(handle)
        vlog("[core] start -> \(result)")
    }

    func stop() {
        guard let handle else { return }
        vb_core_stop(handle)
        vb_core_free(handle)
        self.handle = nil
        speech.cancel()
    }

    func cancel() {
        guard let handle else { return }
        vb_core_cancel(handle)
        speechQueue.async { self.speech.cancel() }
    }

    /// Rebuilds the config after settings changed (provider, model, keys, button map).
    func updateConfiguration() {
        guard let handle else { return }
        var error: UnsafeMutablePointer<CChar>?
        let result = vb_core_update_config(handle, makeConfigJSON(), &error)
        if result != 0 {
            let message = error.map { String(cString: $0) } ?? "未知错误"
            if let error { vb_string_free(error) }
            vlog("[core] 配置更新失败：\(message)")
            return
        }
        vlog("[core] 配置已更新")
    }

    func lastText() -> String {
        guard let handle, let pointer = vb_core_last_text(handle) else { return "" }
        defer { vb_string_free(pointer) }
        return String(cString: pointer)
    }

    // MARK: - Configuration

    private func makeConfigJSON() -> String {
        let settings = AppSettings()
        let provider: String
        switch settings.asrProvider {
        case "stepfun": provider = "stepfun"
        case "whisper": provider = "whisper"
        default: provider = "external"
        }
        usesAppleSpeech = provider == "external"

        let recognitionKey = CloudKey.read(for: .recognition)
        let dedicatedRewriteKey = CloudKey.read(for: .rewrite)
        // Cloud cleanup reuses the recognition key unless a separate one was entered.
        let rewriteKey = dedicatedRewriteKey.isEmpty ? recognitionKey : dedicatedRewriteKey
        let cloudRewrite = settings.rewrite && settings.rewriteEngine == "cloud"

        let config: [String: Any] = [
            "provider": provider,
            "model": settings.asrModel,
            "whisper_model": settings.whisperModel,
            "recognition_key": recognitionKey,
            "rewrite_enabled": cloudRewrite,
            "rewrite_model": settings.rewriteModel,
            "rewrite_key": cloudRewrite ? rewriteKey : "",
            "base_url": "https://torchfun.com",
            "button_actions": buttons.dictionary(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    // MARK: - Static helpers used by the settings UI

    static func version() -> String {
        guard let pointer = vb_version() else { return "?" }
        defer { vb_string_free(pointer) }
        return String(cString: pointer)
    }

    static func backendInfo() -> LocalBackendInfo? {
        guard let pointer = vb_local_backend_info() else { return nil }
        defer { vb_string_free(pointer) }
        guard let data = String(cString: pointer).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return LocalBackendInfo(
            active: object["active"] as? String ?? "?",
            compiled: object["compiled"] as? [String] ?? [],
            systemInfo: object["systemInfo"] as? String ?? ""
        )
    }

    static func modelCatalog() -> [[String: Any]] {
        guard let pointer = vb_model_catalog() else { return [] }
        defer { vb_string_free(pointer) }
        guard let data = String(cString: pointer).data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array
    }

    static func modelInstalled(_ name: String) -> Bool {
        name.withCString { vb_model_available($0) != 0 }
    }

    static func removeModel(_ name: String) -> String? {
        var error: UnsafeMutablePointer<CChar>?
        let result = name.withCString { vb_model_remove($0, &error) }
        guard result != 0 else { return nil }
        let message = error.map { String(cString: $0) } ?? "删除失败"
        if let error { vb_string_free(error) }
        return message
    }

    /// Downloads a model on a background queue; `progress` is called on the main queue.
    static func downloadModel(
        _ name: String,
        progress: @escaping (Double?, UInt64) -> Void,
        completion: @escaping (String?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let box = ProgressBox(progress: progress)
            var error: UnsafeMutablePointer<CChar>?
            let result = name.withCString { pointer in
                vb_download_model(pointer, { context, received, total, hasTotal in
                    guard let context else { return }
                    let box = Unmanaged<ProgressBox>.fromOpaque(context).takeUnretainedValue()
                    let fraction = hasTotal != 0 && total > 0 ? Double(received) / Double(total) : nil
                    box.report(fraction, received)
                }, Unmanaged.passUnretained(box).toOpaque(), &error)
            }
            let message = error.map { pointer -> String in
                defer { vb_string_free(pointer) }
                return String(cString: pointer)
            }
            DispatchQueue.main.async {
                completion(result == 0 ? nil : (message ?? "下载失败"))
            }
            _ = box
        }
    }

    private final class ProgressBox {
        private let progress: (Double?, UInt64) -> Void
        private var lastPercent = -10

        init(progress: @escaping (Double?, UInt64) -> Void) {
            self.progress = progress
        }

        func report(_ fraction: Double?, _ received: UInt64) {
            let percent = fraction.map { Int($0 * 100) } ?? -1
            guard percent < 0 || percent >= lastPercent + 2 else { return }
            if percent >= 0 { lastPercent = percent }
            DispatchQueue.main.async { self.progress(fraction, received) }
        }
    }
}

// MARK: - C callbacks

private func host(_ context: UnsafeMutableRawPointer?) -> CoreHost? {
    guard let context else { return nil }
    return Unmanaged<CoreHost>.fromOpaque(context).takeUnretainedValue()
}

private func text(_ pointer: UnsafePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    return String(cString: pointer)
}

private func coreLog(_ context: UnsafeMutableRawPointer?, _ line: UnsafePointer<CChar>?) {
    guard host(context) != nil, let line = text(line) else { return }
    vlog("[rust] \(line)")
}

private func coreStatus(_ context: UnsafeMutableRawPointer?, _ value: UnsafePointer<CChar>?) {
    guard let host = host(context), let value = text(value) else { return }
    DispatchQueue.main.async { host.onStatus?(value) }
}

private func corePartial(_ context: UnsafeMutableRawPointer?, _ value: UnsafePointer<CChar>?) {
    guard let host = host(context), let value = text(value) else { return }
    DispatchQueue.main.async { host.onPartialText?(value) }
}

private func coreFinal(_ context: UnsafeMutableRawPointer?, _ value: UnsafePointer<CChar>?) {
    guard let host = host(context), let value = text(value) else { return }
    DispatchQueue.main.async { host.onFinalText?(value) }
}

private func coreError(_ context: UnsafeMutableRawPointer?, _ value: UnsafePointer<CChar>?) {
    guard let host = host(context), let value = text(value) else { return }
    DispatchQueue.main.async { host.onError?(value) }
}

private func coreAction(_ context: UnsafeMutableRawPointer?, _ value: UnsafePointer<CChar>?) {
    guard let host = host(context), let value = text(value), let action = ButtonAction(rawValue: value) else { return }
    DispatchQueue.main.async { host.onAction?(action) }
}

private func coreStats(_ context: UnsafeMutableRawPointer?, _ value: UnsafePointer<CChar>?) {
    guard host(context) != nil, let value = text(value),
          let data = value.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    let stats = LocalEngineStats(
        backend: object["backend"] as? String ?? "?",
        model: object["model"] as? String ?? "?",
        audioSeconds: object["audioSeconds"] as? Double ?? 0,
        durationSeconds: object["durationSeconds"] as? Double ?? 0,
        realtimeFactor: object["realtimeFactor"] as? Double ?? 0,
        threads: object["threads"] as? Int ?? 0,
        peakRssMb: object["peakRssMb"] as? Double,
        systemInfo: object["systemInfo"] as? String ?? ""
    )
    EngineStatus.shared.updateStats(stats)
    vlog("[core] 本地识别统计：\(stats.summary)")
}

private func coreSessionStarted(_ context: UnsafeMutableRawPointer?) {
    guard let host = host(context) else { return }
    DispatchQueue.main.async { host.onSessionStart?() }
    host.startSpeechIfNeeded()
}

private func coreCancelled(_ context: UnsafeMutableRawPointer?) {
    guard let host = host(context) else { return }
    DispatchQueue.main.async { host.onCancelled?() }
}

private func corePcm(_ context: UnsafeMutableRawPointer?, _ data: UnsafePointer<UInt8>?, _ length: Int) {
    guard let host = host(context), let data, length > 0 else { return }
    let pcm = Data(bytes: data, count: length)
    host.appendSpeech(pcm)
}

private func corePcmEnd(_ context: UnsafeMutableRawPointer?) {
    guard let host = host(context) else { return }
    host.finishSpeech()
}

private func coreLoadSecret(_ context: UnsafeMutableRawPointer?, _ device: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard host(context) != nil, let device = text(device), let secret = KeychainStore.loadSecret(deviceID: device) else {
        return nil
    }
    return vb_string_alloc(secret)
}

private func coreSaveSecret(_ context: UnsafeMutableRawPointer?, _ device: UnsafePointer<CChar>?, _ secret: UnsafePointer<CChar>?) {
    guard host(context) != nil, let device = text(device), let secret = text(secret) else { return }
    _ = KeychainStore.saveSecret(secret, deviceID: device)
}

extension CoreHost {
    fileprivate func startSpeechIfNeeded() {
        guard usesAppleSpeech else { return }
        speechQueue.async {
            if !self.speech.start() {
                vlog("[core] Apple 本机识别不可用，回退到浮动窗显示")
            }
        }
    }

    fileprivate func appendSpeech(_ pcm: Data) {
        speechQueue.async { self.speech.append(pcm: pcm) }
    }

    fileprivate func finishSpeech() {
        speechQueue.async { self.speech.finish() }
    }
}
