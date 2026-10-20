import XCTest
import Security
@testable import VibeBoardPlus

final class CloudKeyTests: XCTestCase {
    func testIndependentCredentialsPreserveLegacyConfiguration() throws {
        let service = "vibeboardplus.tests.\(UUID().uuidString)"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        defer { SecItemDelete(query as CFDictionary) }
        var legacy = query
        legacy[kSecAttrAccount as String] = "stepfun"
        legacy[kSecValueData as String] = Data("legacy-test-placeholder".utf8)
        XCTAssertEqual(SecItemAdd(legacy as CFDictionary, nil), errSecSuccess)
        XCTAssertEqual(CloudKey.read(for: .recognition, service: service), "legacy-test-placeholder")
        XCTAssertEqual(CloudKey.read(for: .rewrite, service: service), "legacy-test-placeholder")
        XCTAssertTrue(CloudKey.save("asr-test-placeholder", for: .recognition, service: service))
        XCTAssertEqual(CloudKey.read(for: .rewrite, service: service), "legacy-test-placeholder")
        XCTAssertTrue(CloudKey.save("rewrite-test-placeholder", for: .rewrite, service: service))
        XCTAssertEqual(CloudKey.read(for: .recognition, service: service), "asr-test-placeholder")
        XCTAssertEqual(CloudKey.read(for: .rewrite, service: service), "rewrite-test-placeholder")
    }
}
