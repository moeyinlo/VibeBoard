import Foundation
import Security

enum CloudKey {
    enum Purpose: String { case recognition, rewrite }

    static func read(for purpose: Purpose, service: String = "app.vibeboardplus.cloud") -> String {
        // Existing shared credentials remain a migration fallback for each independent slot.
        read(account: "stepfun.\(purpose.rawValue)", service: service) ?? read(account: "stepfun", service: service) ?? ""
    }

    private static func read(account: String, service: String) -> String? {
        var result: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, for purpose: Purpose, service: String = "app.vibeboardplus.cloud") -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "stepfun.\(purpose.rawValue)"]
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            return SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }
}

struct CloudService {
    let key: String
    let session: URLSession

    init(key: String, session: URLSession = .shared) {
        self.key = key; self.session = session
    }

    func request(path: String, body: Data, contentType: String) throws -> URLRequest {
        guard !key.isEmpty else { throw SemanticRewriteError.unavailable("请在对应设置页填写 StepFun API Key") }
        var request = URLRequest(url: URL(string: "https://api.stepfun.com/v1/" + path)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 55
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    func send(_ request: URLRequest) async throws -> Data {
        diag("StepFun HTTP 请求 \(request.url?.path ?? "unknown")")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        diag("StepFun HTTP 状态 \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw SemanticRewriteError.unavailable("StepFun 请求失败（HTTP \(code)），请检查密钥、额度和模型")
        }
        return data
    }

    func rewrite(_ text: String, model: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["model": model, "stream": false, "max_tokens": 8192,
            "messages": [["role": "system", "content": SemanticRewriter.instructions],
                         ["role": "user", "content": text]]])
        let data = try await send(request(path: "chat/completions", body: body, contentType: "application/json"))
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
                let finish_reason: String?
            }
            let choices: [Choice]
        }
        let result = try JSONDecoder().decode(Response.self, from: data)
        if let reason = result.choices.first?.finish_reason, reason != "stop" { throw SemanticRewriteError.invalidResult }
        return try SemanticRewriter.validate(result.choices.first?.message.content ?? "", original: text)
    }

    static func wav(_ pcm: Data) -> Data {
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { var le = value.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        append(UInt32(pcm.count + 36)); data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(16000))
        append(UInt32(32000)); append(UInt16(2)); append(UInt16(16))
        data.append(Data("data".utf8)); append(UInt32(pcm.count)); data.append(pcm)
        return data
    }

    static func multipart(pcm: Data, model: String, boundary: String) -> Data {
        var body = Data()
        for (name, value) in [("model", model), ("response_format", "json")] {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav(pcm)); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    func transcribe(_ pcm: Data, model: String) async throws -> String {
        let boundary = UUID().uuidString
        let data = try await send(request(path: "audio/transcriptions",
            body: Self.multipart(pcm: pcm, model: model, boundary: boundary),
            contentType: "multipart/form-data; boundary=\(boundary)"))
        struct Response: Decodable { let text: String }
        return try JSONDecoder().decode(Response.self, from: data).text
    }
}

// All session state and decoded audio are owned by the main queue.
final class CloudASRProvider: ASRProvider {
    let name = "stepfun"
    let latencyClass: LatencyClass = .remote
    private let decoder = DeviceAudioDecoder()
    private var pcm = Data()
    private var recording = false
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var model = ""
    private var service = CloudService(key: "")
    private let stream = StepFunStream()
    private var totalBytes = 0
    var onText: ((String, Bool) -> Void)?
    var onError: ((String) -> Void)?
    func startSession() {
        stop(); decoder.reset(); recording = true
        model = AppSettings().asrModel; service = CloudService(key: CloudKey.read(for: .recognition))
        diag("云端会话开始 model=\(model) key=\(service.key.isEmpty ? "missing" : "configured")")
        totalBytes = 0
        if model.hasSuffix("-stream") {
            stream.onText = { [weak self] text, final in self?.onText?(text, final) }
            stream.onError = { [weak self] message in self?.stop(); self?.onError?(message) }
            stream.start(model: model, key: service.key)
        }
    }

    func sendAudio(_ data: Data) {
        guard recording else { return }
        let previousCount = pcm.count
        for buffer in decoder.decode(data) {
            let count = Int(buffer.frameLength)
            if let samples = buffer.int16ChannelData {
                pcm.append(Data(bytes: samples[0], count: count * 2))
            } else if let samples = buffer.floatChannelData {
                for index in 0..<count {
                    let sample = samples[0][index]
                    var value = Int16(max(-32768, min(32767, (sample.isFinite ? sample : 0) * 32767))).littleEndian
                    withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
                }
            }
        }
        totalBytes += pcm.count - previousCount
        if model.hasSuffix("-stream") { stream.append(pcm); pcm.removeAll() }
        if totalBytes > 16000 * 2 * 300 {
            stop(); onError?("单次云端录音最多 5 分钟，请分段录制")
        }
    }

    func finishSession() {
        guard recording else { return }
        recording = false
        if model.hasSuffix("-stream") { stream.finish(); return }
        let audio = pcm; pcm.removeAll()
        diag("云端音频上传准备：\(audio.count)B PCM")
        guard !audio.isEmpty else { onError?("未收到设备音频，请检查按键及串口连接"); return }
        let current = generation, client = service, selectedModel = model
        task = Task { @MainActor [weak self] in
            do {
                let text = try await client.transcribe(audio, model: selectedModel)
                guard let self, self.generation == current else { return }
                self.onText?(text, true)
            } catch {
                guard let self, self.generation == current else { return }
                diag("云端识别请求失败：\(error.localizedDescription)")
                self.onError?((error as? SemanticRewriteError)?.errorDescription ?? "云端识别失败，请检查网络")
            }
        }
    }

    func stop() {
        stream.stop()
        generation = UUID(); task?.cancel(); task = nil; recording = false; pcm.removeAll()
    }
}
