import Foundation
import CryptoKit

/// 设备注册与 token 交换（协议从 VibeBoard.app v0.5.4 逆向还原，见 docs/PROTOCOL.md §2-3）。
///
/// 签名算法（反汇编确认）：
///   message   = deviceID + "|" + timestamp + "|" + nonce
///   signature = hex(HMAC<SHA256>(key: secret, message: message))
final class DeviceAuthClient {
    struct RegisterResult {
        let deviceID: String
        let secret: String?
        let provisioned: Bool
    }

    struct TokenResult {
        let token: String
        let expiresAt: Date?
    }

    enum AuthError: Error, CustomStringConvertible {
        case invalidURL(String)
        case invalidResponse
        case serverError(Int, String?)

        var description: String {
            switch self {
            case .invalidURL(let u): return "invalid relay URL: \(u)"
            case .invalidResponse: return "invalid response from auth server"
            case .serverError(let code, let body): return "auth server error \(code): \(body ?? "")"
            }
        }
    }

    let baseURL: URL
    private let session: URLSession
    private let queue = DispatchQueue(label: "vibeboardplus.auth")

    /// token 缓存：原 App 有 cachedToken 但不利用 expiresAt 预刷新，这里提前 60s 视为过期。
    private var cached: (token: String, expiresAt: Date?)?
    private let tokenTTLGrace: TimeInterval = 60

    init(relayURL: String = "https://torchfun.com", session: URLSession = .shared) {
        self.baseURL = URL(string: relayURL) ?? URL(string: "https://torchfun.com")!
        self.session = session
    }

    // MARK: - 签名（严格按还原的算法）

    static func computeSignature(secret: String, deviceID: String, timestamp: Int, nonce: String) -> String {
        let message = deviceID + "|" + String(timestamp) + "|" + nonce
        let key = SymmetricKey(data: Data(secret.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 注册

    func registerDevice(mac: String, hardware: String, registrationToken: String?) async throws -> RegisterResult {
        var body: [String: Any] = ["mac": mac, "hardware": hardware]
        if let t = registrationToken { body["registration_token"] = t }
        let data = try await post(path: "/v1/device/register", json: body)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceID = obj["device_id"] as? String else {
            throw AuthError.invalidResponse
        }
        // 实测响应字段：device_id / device_secret / registered
        let secret = obj["device_secret"] as? String
        let provisioned = obj["registered"] as? Bool ?? (secret != nil)
        return RegisterResult(deviceID: deviceID, secret: secret, provisioned: provisioned)
    }

    // MARK: - Token（带缓存与预刷新）

    func validToken(deviceID: String, secret: String) async throws -> String {
        if let c = cached, let exp = c.expiresAt, exp.timeIntervalSinceNow > tokenTTLGrace {
            return c.token
        }
        if let c = cached, c.expiresAt == nil {
            return c.token
        }
        let result = try await exchangeToken(deviceID: deviceID, secret: secret)
        cached = (result.token, result.expiresAt)
        return result.token
    }

    func clearCachedToken() { cached = nil }

    func exchangeToken(deviceID: String, secret: String) async throws -> TokenResult {
        let timestamp = Int(Date().timeIntervalSince1970)
        let nonce = UUID().uuidString
        let signature = Self.computeSignature(secret: secret, deviceID: deviceID, timestamp: timestamp, nonce: nonce)
        let data = try await post(path: "/v1/device/token", json: [
            "device_id": deviceID,
            "timestamp": timestamp,
            "nonce": nonce,
            "signature": signature,
        ])
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["token"] as? String else {
            throw AuthError.invalidResponse
        }
        var expiresAt: Date?
        if let exp = obj["expiresAt"] as? Double { expiresAt = Date(timeIntervalSince1970: exp) }
        if let exp = obj["expires_at"] as? Double { expiresAt = Date(timeIntervalSince1970: exp) }
        if let ttl = obj["expires_in"] as? Double { expiresAt = Date().addingTimeInterval(ttl) }
        return TokenResult(token: token, expiresAt: expiresAt)
    }

    // MARK: - HTTP

    private func post(path: String, json: [String: Any]) async throws -> Data {
        guard let url = URL(string: baseURL.absoluteString + path) else {
            throw AuthError.invalidURL(baseURL.absoluteString + path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        vlog("[auth] POST \(url)")
        // 回调 + continuation：CLI/dispatchMain 进程中 async 版 data(for:) 可能不恢复
        let (data, response): (Data, URLResponse) = try await withCheckedThrowingContinuation { cont in
            session.dataTask(with: request) { data, response, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: (data ?? Data(), response ?? URLResponse()))
                }
            }.resume()
            vlog("[auth] task resumed")
        }
        guard let http = response as? HTTPURLResponse else { throw AuthError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AuthError.serverError(http.statusCode, String(data: data, encoding: .utf8))
        }
        return data
    }
}
