import XCTest
@testable import VibeBoardPlus

final class RecognitionOutputTests: XCTestCase {
    func testRevisionsPreserveSurroundingTextAndUseUTF16Caret() {
        var draft = TranscriptReplacement(original: "前文：。后文", selection: NSRange(location: 3, length: 0))
        draft.update("你好")
        XCTAssertEqual(draft.currentValue, "前文：你好。后文")
        draft.update("你好世界")
        XCTAssertEqual(draft.currentValue, "前文：你好世界。后文")
        XCTAssertEqual(draft.caret, NSRange(location: 7, length: 0))
        draft.update("\u{1F600}")
        XCTAssertEqual(draft.caret.location, 5)
    }

    func testSelectedTextIsReplacedOnlyOnce() {
        var draft = TranscriptReplacement(original: "hello old world", selection: NSRange(location: 6, length: 3))
        draft.update("new")
        draft.update("better")
        XCTAssertEqual(draft.currentValue, "hello better world")
        XCTAssertEqual(draft.replacementRange, NSRange(location: 6, length: 6))
    }

    func testInvalidRewriteDoesNotReplaceOriginal() {
        XCTAssertThrowsError(try SemanticRewriter.validate("  ", original: "你好"))
        XCTAssertThrowsError(try SemanticRewriter.validate(String(repeating: "x", count: 100), original: "你好"))
        XCTAssertEqual(try SemanticRewriter.validate(" 你好。\n", original: "你好"), "你好。")
    }
}
