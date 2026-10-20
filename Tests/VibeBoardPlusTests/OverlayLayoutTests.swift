import AppKit
import XCTest
@testable import VibeBoardPlus

final class OverlayLayoutTests: XCTestCase {
    @MainActor
    func testOverlayLayoutAndRender() throws {
        _ = NSApplication.shared
        let overlay = RecognitionOverlay()
        for (name, text) in [("listening", ""), ("short", "我们一起跨过高山草地。"),
                             ("long", String(repeating: "这是一段连续的语音识别结果，用来检查自动换行和滚动。", count: 25))] {
            overlay.render(text, final: name != "listening")
            XCTAssertLessThanOrEqual(overlay.panel.frame.height, 248)
            XCTAssertGreaterThanOrEqual(overlay.panel.frame.height, 56)
            let content = try XCTUnwrap(overlay.panel.contentView)
            let scroll = try XCTUnwrap(content.subviews.compactMap { $0 as? NSScrollView }.first)
            if !text.isEmpty {
                XCTAssertTrue(content.bounds.contains(scroll.frame))
                XCTAssertGreaterThan(scroll.frame.width, 400)
                XCTAssertEqual((scroll.documentView as? NSTextView)?.string, text)
            }
            for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                content.appearance = NSAppearance(named: appearanceName)
                content.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vibeboardplus-overlay-qa")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try png.write(to: directory.appendingPathComponent("\(name)-\(appearanceName.rawValue).png"))
                print("Overlay snapshot: \(directory.path)/\(name)-\(appearanceName.rawValue).png")
            }
        }
    }
}
