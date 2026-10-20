import Foundation
import XCTest
@testable import VibeBoardPlus

private final class CloudMockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class CloudServiceTests: XCTestCase {
    func testStreamingModelsUseCorrectRevisionSemantics() {
        let event: [String: Any] = ["text": "今天下午三点。"]
        XCTAssertEqual(StepFunStreamProtocol.partial(event, previous: "今天上午", model: "stepaudio-2.5-asr-stream"), "今天下午三点。")
        XCTAssertEqual(StepFunStreamProtocol.partial(["text": "下午"], previous: "今天", model: "step-asr-1.1-stream"), "今天下午")
        let configuration = StepFunStreamProtocol.configuration(model: "stepaudio-2.5-asr-stream")
        let session = configuration["session"] as? [String: Any]
        let audio = session?["audio"] as? [String: Any]
        let input = audio?["input"] as? [String: Any]
        let format = input?["format"] as? [String: Any]
        XCTAssertEqual(format?["codec"] as? String, "pcm_s16le")
        XCTAssertEqual(format?["rate"] as? Int, 16000)
        XCTAssertNil(input?["turn_detection"])
    }
    private func client() -> CloudService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudMockProtocol.self]
        return CloudService(key: "test-placeholder", session: URLSession(configuration: configuration))
    }
    func testWAVAndMultipartCarryActualPCM() throws {
        let pcm = Data([0, 0, 255, 127, 0, 128])
        let wav = CloudService.wav(pcm)
        XCTAssertEqual(wav.count, pcm.count + 44)
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .utf8), "RIFF")
        XCTAssertEqual(Array(wav[24..<28]), [128, 62, 0, 0])
        XCTAssertEqual(Array(wav[40..<44]), [6, 0, 0, 0])
        XCTAssertEqual(wav.suffix(pcm.count), pcm)
        let multipart = CloudService.multipart(pcm: pcm, model: "step-asr", boundary: "test-boundary")
        XCTAssertNotNil(multipart.range(of: wav))
        XCTAssertNotNil(multipart.range(of: Data("\r\nstep-asr\r\n".utf8)))
        XCTAssertTrue(multipart.suffix(19).elementsEqual(Data("--test-boundary--\r\n".utf8)))
    }
    func testTranscriptionResponseAndAuthorization() async throws {
        CloudMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/audio/transcriptions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-placeholder")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data;") == true)
            return (200, Data("{\"text\":\"你好。\"}".utf8))
        }
        let result = try await client().transcribe(Data([0, 0]), model: "stepaudio-2.5-asr")
        XCTAssertEqual(result, "你好。")
    }
    func testRewriteAndHTTPFailure() async throws {
        CloudMockProtocol.handler = { _ in
            (200, Data("{\"choices\":[{\"message\":{\"content\":\"你好，今天开会。\"}}]}".utf8))
        }
        let result = try await client().rewrite("你好今天开会", model: "step-3.5-flash")
        XCTAssertEqual(result, "你好，今天开会。")
        CloudMockProtocol.handler = { _ in (401, Data("private server details".utf8)) }
        do {
            _ = try await client().rewrite("你好", model: "step-3.5-flash")
            XCTFail("Expected authentication error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("401"))
            XCTAssertFalse(error.localizedDescription.contains("private server details"))
        }
    }
    func testMissingKeyFailsBeforeNetworking() {
        XCTAssertThrowsError(try CloudService(key: "").request(path: "chat/completions", body: Data(), contentType: "application/json"))
    }
}
