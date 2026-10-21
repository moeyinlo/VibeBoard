import Foundation
import Security

enum CloudKey {
    enum Purpose: String { case recognition, rewrite }

    static func read(for purpose: Purpose, service: String = "app.vibeboardplus.cloud") -> String {
        // Existing shared credentials remain a migration fallback for each independent slot,
        // and the recognition key is reused for cleanup so users only configure one key.
        read(account: "stepfun.\(purpose.rawValue)", service: service)
            ?? read(account: "stepfun", service: service)
            ?? read(account: "stepfun.recognition", service: service)
            ?? ""
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

/// Semantic cleanup through StepFun chat completions.
///
/// Recognition moved into the Rust core; the macOS shell keeps local cleanup because it can
/// use Apple Foundation Models, and falls back to this cloud client.
struct CloudService {
    let key: String
    let session: URLSession

    init(key: String, session: URLSession = .shared) {
        self.key = key; self.session = session
    }

    private func request(path: String, body: Data, contentType: String) throws -> URLRequest {
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
}
