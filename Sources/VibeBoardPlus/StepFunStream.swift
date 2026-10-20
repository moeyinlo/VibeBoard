import Foundation

protocol SpeechWebSocket: AnyObject {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}
extension URLSessionWebSocketTask: SpeechWebSocket {}

enum StepFunStreamProtocol {
    static func configuration(model: String) -> [String: Any] {
        ["type": "session.update", "event_id": UUID().uuidString,
         "session": ["audio": ["input": [
            "format": ["type": "pcm", "codec": "pcm_s16le", "rate": 16000, "bits": 16, "channel": 1],
            "transcription": ["model": model, "language": "zh", "full_rerun_on_commit": true, "enable_itn": true]
         ]]]]
    }
    static func partial(_ event: [String: Any], previous: String, model: String) -> String {
        let text = event["text"] as? String ?? ""
        return model == "step-asr-1.1-stream" ? previous + text : text
    }
}

// Main-queue ownership keeps append, commit, cancellation, and callbacks ordered.
final class StepFunStream {
    private var socket: SpeechWebSocket?
    private let makeSocket: (URLRequest) -> SpeechWebSocket
    private var receiver: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var connectionTimeout: DispatchWorkItem?
    private var generation = UUID()
    private var ready = false
    private var finishing = false
    private var committing = false
    private var pending = Data()
    private var text = ""
    private var model = ""
    private var sentChunks = 0
    var onText: ((String, Bool) -> Void)?
    var onError: ((String) -> Void)?

    init(makeSocket: @escaping (URLRequest) -> SpeechWebSocket = { URLSession.shared.webSocketTask(with: $0) }) {
        self.makeSocket = makeSocket
    }

    func start(model: String, key: String) {
        stop()
        guard !key.isEmpty else { onError?("请在语音识别设置中填写 StepFun API Key"); return }
        self.model = model
        diag("StepFun WebSocket 建连 model=\(model)")
        var request = URLRequest(url: URL(string: "wss://api.stepfun.com/v1/realtime/asr/stream")!)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        let socket = makeSocket(request)
        self.socket = socket
        let current = generation
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == current else { return }
            self.fail("云端连接超时，请检查网络")
        }
        connectionTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
        socket.resume()
        receiver = Task { @MainActor [weak self] in
            do {
                try Task.checkCancellation()
                try await socket.send(Self.message(StepFunStreamProtocol.configuration(model: model)))
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard let self, self.generation == current else { return }
                    let data: Data
                    switch message {
                    case .string(let value): data = Data(value.utf8)
                    case .data(let value): data = value
                    @unknown default: continue
                    }
                    guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    self.handle(event)
                }
            } catch {
                guard let self, self.generation == current else { return }
                self.fail("StepFun 流式连接失败，请检查网络和密钥")
            }
        }
    }
    private func handle(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "session.updated":
            diag("StepFun 会话就绪")
            connectionTimeout?.cancel(); ready = true; drain()
        case "conversation.item.input_audio_transcription.delta":
            text = StepFunStreamProtocol.partial(event, previous: text, model: model)
            onText?(text, false)
        case "conversation.item.input_audio_transcription.completed":
            guard committing else { return }
            let final = event["transcript"] as? String ?? text
            diag("StepFun 转录完成：\(final.count) 字符")
            stop(); onText?(final, true)
        case "error":
            diag("StepFun 错误事件 code=\((event["error"] as? [String: Any])?["code"] ?? "unknown")")
            fail("StepFun 流式识别失败，请检查模型与音频配置")
        default: break
        }
    }
    func append(_ pcm: Data) {
        guard socket != nil, !finishing else { return }
        pending.append(pcm)
        guard pending.count <= 16000 * 2 * 15 else { fail("网络发送过慢，请重新录制"); return }
        drain()
    }
    func finish() { finishing = true; drain() }
    private func drain() {
        guard ready, sender == nil, let socket else { return }
        let current = generation
        sender = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                while self.generation == current {
                    if !self.pending.isEmpty {
                        let size = min(self.pending.count, 6400)
                        let chunk = Data(self.pending.prefix(size))
                        self.pending.removeFirst(size)
                        try await socket.send(Self.message(["type": "input_audio_buffer.append",
                            "event_id": UUID().uuidString, "audio": chunk.base64EncodedString()]))
                        self.sentChunks += 1
                        if self.sentChunks == 1 || self.sentChunks % 50 == 0 { diag("StepFun 已发送音频块 \(self.sentChunks)") }
                    } else if self.finishing && !self.committing {
                        self.committing = true
                        try await socket.send(Self.message(["type": "input_audio_buffer.commit", "event_id": UUID().uuidString]))
                        diag("StepFun 音频已提交：\(self.sentChunks) 块")
                    } else { break }
                }
                if self.generation == current { self.sender = nil }
            } catch {
                guard self.generation == current else { return }
                self.fail("云端音频发送失败，请重新录制")
            }
        }
    }
    private static func message(_ object: [String: Any]) throws -> URLSessionWebSocketTask.Message {
        .string(String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }
    private func fail(_ message: String) { diag(message); stop(); onError?(message) }
    func stop() {
        generation = UUID(); connectionTimeout?.cancel()
        receiver?.cancel(); sender?.cancel(); receiver = nil; sender = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        ready = false; finishing = false; committing = false; pending.removeAll(); text = ""
        sentChunks = 0
    }
}
