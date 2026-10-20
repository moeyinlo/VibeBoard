import XCTest
import Foundation
@testable import VibeBoardPlus

private final class MockSpeechSocket: SpeechWebSocket {
    let events: AsyncStream<URLSessionWebSocketTask.Message>
    let continuation: AsyncStream<URLSessionWebSocketTask.Message>.Continuation
    var onSend: (([String: Any]) -> Void)?
    var closed = false
    init() {
        var saved: AsyncStream<URLSessionWebSocketTask.Message>.Continuation!
        events = AsyncStream { saved = $0 }
        continuation = saved
    }
    func resume() {}
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        if case .string(let text) = message {
            onSend?(try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any])
        }
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        var iterator = events.makeAsyncIterator()
        guard let message = await iterator.next() else { throw CancellationError() }
        return message
    }
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        closed = true; continuation.finish()
    }
    func emit(_ event: [String: Any]) throws {
        continuation.yield(.string(String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)))
    }
}

final class StepFunStreamTests: XCTestCase {
    @MainActor
    func testReleaseBeforeReadySendsAudioBeforeCommitAndReturnsFinal() async throws {
        let socket = MockSpeechSocket()
        let stream = StepFunStream { _ in socket }
        var sent: [String] = []
        let committed = expectation(description: "commit after queued audio")
        socket.onSend = { event in
            let type = event["type"] as! String
            sent.append(type)
            if type == "input_audio_buffer.append" { XCTAssertEqual(event["audio"] as? String, Data([1, 2]).base64EncodedString()) }
            if type == "input_audio_buffer.commit" { committed.fulfill() }
        }
        let final = expectation(description: "completed transcript")
        stream.onText = { text, done in
            if done { XCTAssertEqual(text, "你好。"); final.fulfill() }
        }
        stream.start(model: "stepaudio-2.5-asr-stream", key: "test")
        stream.append(Data([1, 2])); stream.finish()
        try socket.emit(["type": "session.updated"])
        await fulfillment(of: [committed], timeout: 2)
        XCTAssertEqual(sent, ["session.update", "input_audio_buffer.append", "input_audio_buffer.commit"])
        try socket.emit(["type": "conversation.item.input_audio_transcription.completed", "transcript": "你好。"])
        await fulfillment(of: [final], timeout: 2)
        XCTAssertTrue(socket.closed)
    }
    @MainActor
    func testCancellationClosesSocketAndDiscardsBufferedAudio() async throws {
        let socket = MockSpeechSocket()
        let stream = StepFunStream { _ in socket }
        stream.onText = { _, _ in XCTFail("Canceled session delivered text") }
        stream.onError = { _ in XCTFail("Canceled session delivered error") }
        stream.start(model: "stepaudio-2.5-asr-stream", key: "test")
        stream.append(Data([0, 0])); stream.stop()
        try socket.emit(["type": "session.updated"])
        await Task.yield()
        XCTAssertTrue(socket.closed)
    }
}
