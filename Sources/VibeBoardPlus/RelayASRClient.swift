import Foundation
import zlib

/// Relay ASR WebSocket 客户端。
///
/// 与原 App 的差异（稳定性加固，见 docs/PROTOCOL.md §6）：
/// - 任何断线都走指数退避自动重连（原 App 仅 4001 鉴权失败时重试一次）
/// - token 依据 expiresAt 预刷新，避免会话中途过期
/// - 会话中断后自动重建（start_session / audio / final_audio_sent / finish_session）
/// - 端点故障自动切换到备用 ASR provider
final class RelayASRClient: NSObject {
    struct Options {
        var relayURL: URL
        var apiKey: String?   // relay 的 x-api-key（StepFun ASR 上游凭据）
        var hotwords: [String] = []
        var maxBackoff: TimeInterval = 60
        var baseBackoff: TimeInterval = 1
        /// 备用远端端点（可插拔）：主 relay 反复失败时按序切换。
        /// 支持任意 WebSocket ASR 服务（stepfun、bytedance、xiaozhi…），需各服务自己的鉴权参数。
        var fallbackProviders: [(name: String, url: URL)] = []
    }

    enum State: String {
        case idle, connecting, connected, sessionActive, backoff, failed
    }

    private(set) var state: State = .idle
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession!
    private var reconnectAttempt = 0
    private var fallbackIndex = -1
    private var currentSessionID: String?
    private var pendingAudio = [Data]()
    private var manuallyStopped = false
    private let queue = DispatchQueue(label: "vibeboardplus.asr")

    let options: Options
    var onText: ((String, Bool) -> Void)?  // (text, isFinal)
    var onStateChange: ((State) -> Void)?

    private let auth: DeviceAuthClient
    private let deviceIDProvider: () -> String?
    private let secretProvider: () -> String?

    init(options: Options,
         auth: DeviceAuthClient,
         deviceIDProvider: @escaping () -> String?,
         secretProvider: @escaping () -> String?) {
        self.options = options
        self.auth = auth
        self.deviceIDProvider = deviceIDProvider
        self.secretProvider = secretProvider
        super.init()
        self.session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    // MARK: - 会话控制

    func startSession() {
        queue.async { [self] in
            manuallyStopped = false
            connect()
        }
    }

    func sendAudio(_ data: Data) {
        queue.async { [self] in
            guard state == .sessionActive || state == .connected, let socket = socket else {
                pendingAudio.append(data)
                return
            }
            // 原协议音频块 gzip 压缩后发送（PROTOCOL.md §4）
            let chunk = (try? data.gzipped()) ?? data
            socket.send(.data(chunk)) { _ in }
        }
    }

    func finishSession() {
        queue.async { [self] in
            guard let id = currentSessionID, let socket = socket else { return }
            let msg: [String: Any] = ["type": "session.finish", "session_id": id]
            if let data = try? JSONSerialization.data(withJSONObject: msg),
               let text = String(data: data, encoding: .utf8) {
                vlog("[relay->] \(text)")
                socket.send(.string(text)) { _ in }
            }
            currentSessionID = nil
            state = .connected
            onStateChange?(state)
        }
    }

    func stop() {
        queue.async { [self] in
            manuallyStopped = true
            finishSession()
            socket?.cancel(with: .normalClosure, reason: nil)
            socket = nil
            state = .idle
            onStateChange?(state)
        }
    }

    // MARK: - 连接（含指数退避 + 端点切换）

    private func currentURL() -> URL {
        if fallbackIndex >= 0, fallbackIndex < options.fallbackProviders.count {
            return options.fallbackProviders[fallbackIndex].url
        }
        return options.relayURL
    }

    private func connect() {
        guard let deviceID = deviceIDProvider(), let secret = secretProvider() else {
            state = .failed
            onStateChange?(state)
            return
        }
        state = .connecting
        onStateChange?(state)
        var request = URLRequest(url: currentURL())
        if let apiKey = options.apiKey {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        // 鉴权在连接建立后由服务端校验；原协议 4001 → 刷新 token 重试一次
        Task.detached { [self] in
            do {
                let token = try await auth.validToken(deviceID: deviceID, secret: secret)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            } catch {
                // token 获取失败仍尝试连接，由服务端反馈错误
            }
            queue.async { [self] in
                let task = session.webSocketTask(with: request)
                socket = task
                task.resume()
                receiveLoop(on: task)
                startNewSession(on: task)
            }
        }
    }

    private func startNewSession(on socket: URLSessionWebSocketTask) {
        let sessionID = UUID().uuidString
        // 实测验证的 schema：type=session.start，pipeline 必须是数组
        var msg: [String: Any] = [
            "type": "session.start",
            "session_id": sessionID,
            "pipeline": ["asr"],
            "codec": "opus",
            "container": "ogg",
            "sample_rate": 16000,
            "result_type": "full",
            "show_utterances": true,
        ]
        if !options.hotwords.isEmpty { msg["hotwords"] = options.hotwords }
        guard let data = try? JSONSerialization.data(withJSONObject: msg), let text = String(data: data, encoding: .utf8) else { return }
        vlog("[relay->] \(text)")
        socket.send(.string(text)) { [self] _ in }
        currentSessionID = sessionID
        state = .sessionActive
        onStateChange?(state)
        // 冲洗断线期间排队的音频
        let queued = pendingAudio
        pendingAudio.removeAll()
        for chunk in queued { sendAudio(chunk) }
    }

    private func receiveLoop(on socket: URLSessionWebSocketTask) {
        socket.receive { [self] result in
            queue.async { [self] in
                guard socket === self.socket else { return }
                switch result {
                case .success(let message):
                    handle(message: message)
                    receiveLoop(on: socket)
                case .failure(let error):
                    handleDisconnect(reason: error.localizedDescription)
                }
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            vlog("[relay<-] \(text.prefix(200))")
            guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
            let type = obj["type"] as? String ?? obj["event"] as? String
            switch type {
            case "session.started", "session_started":
                state = .sessionActive
                onStateChange?(state)
            case "asr.partial", "partial", "partial_text":
                onText?((obj["text"] as? String) ?? "", false)
            case "asr.final", "segment", "final", "final_text":
                onText?((obj["text"] as? String) ?? "", true)
            case "session.finished", "session_finished":
                state = .connected
                onStateChange?(state)
            default:
                break
            }
        case .data:
            break
        @unknown default:
            break
        }
    }

    private func handleDisconnect(reason: String) {
        guard !manuallyStopped else { return }
        socket = nil
        currentSessionID = nil
        reconnectAttempt += 1

        // 指数退避；连续失败达到阈值后切换备用 ASR 端点
        if reconnectAttempt % 5 == 0 {
            fallbackIndex += 1
            if fallbackIndex >= options.fallbackProviders.count { fallbackIndex = -1 }
        }
        let delay = min(options.baseBackoff * pow(2, Double(min(reconnectAttempt, 10))), options.maxBackoff)
        state = .backoff
        onStateChange?(state)
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            guard !manuallyStopped else { return }
            connect()
        }
    }
}

extension RelayASRClient: ASRProvider {
    var name: String {
        if fallbackIndex >= 0, fallbackIndex < options.fallbackProviders.count {
            return options.fallbackProviders[fallbackIndex].name
        }
        return "relay"
    }
    var latencyClass: LatencyClass { .remote }
}

extension RelayASRClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        queue.async { [self] in
            guard webSocketTask === socket else { return }
            reconnectAttempt = 0
            state = .connected
            onStateChange?(state)
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.async { [self] in
            guard webSocketTask === socket else { return }
            // 4001=鉴权失败：清缓存换 token 再连；4003/4008 为不可恢复，直接失败
            if closeCode.rawValue == 4001 {
                auth.clearCachedToken()
            }
            if closeCode.rawValue == 4003 || closeCode.rawValue == 4008 {
                state = .failed
                onStateChange?(state)
                manuallyStopped = true
                return
            }
            handleDisconnect(reason: "closed \(closeCode.rawValue)")
        }
    }
}

enum GzipError: Error { case compressionFailed }

extension Data {
    /// gzip 封装（RFC 1952）：gzip 头 + raw deflate 体 + CRC32/长度尾
    func gzipped() throws -> Data {
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff])
        out.append(try rawDeflate())
        let crc = crc32Value
        out.append(contentsOf: Swift.withUnsafeBytes(of: crc.littleEndian) { Data($0) })
        out.append(contentsOf: Swift.withUnsafeBytes(of: UInt32(count).littleEndian) { Data($0) })
        return out
    }

    private func rawDeflate() throws -> Data {
        var stream = z_stream()
        let status = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
                                   -15, 8, Z_DEFAULT_STRATEGY,
                                   ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw GzipError.compressionFailed }
        defer { deflateEnd(&stream) }

        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 16384)
        try withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = UInt32(count)
            var finished = false
            repeat {
                var produced = 0
                let result = chunk.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = UInt32(buffer.count)
                    let rc = deflate(&stream, Z_FINISH)
                    finished = rc == Z_STREAM_END
                    return (rc == Z_OK || finished) ? Int32(buffer.count - Int(stream.avail_out)) : -1
                }
                guard result >= 0 else { throw GzipError.compressionFailed }
                produced = Int(result)
                output.append(contentsOf: chunk[0..<produced])
            } while !finished
        }
        return output
    }

    var crc32Value: UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in self {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1
            }
        }
        return ~crc
    }
}
