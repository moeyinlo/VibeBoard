import AppKit
import XCTest
@testable import VibeBoardPlus

final class AppSettingsTests: XCTestCase {
    @MainActor
    func testSecureFieldPastesAndReplacesSelection() throws {
        _ = NSApplication.shared
        let window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                                styleMask: [.titled], backing: .buffered, defer: false)
        let field = NSSecureTextField(frame: NSRect(x: 10, y: 10, width: 300, height: 24))
        window.contentView?.addSubview(field)
        field.selectText(nil)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(editor.isFieldEditor)
        let pasteboard = NSPasteboard.general
        let original = (pasteboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer {
            pasteboard.clearContents()
            if !original.isEmpty { pasteboard.writeObjects(original) }
        }
        pasteboard.clearContents()
        pasteboard.setString("test-key-placeholder", forType: .string)
        func command(_ character: String) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0))
            XCTAssertTrue(window.performKeyEquivalent(with: event))
        }
        try command("v")
        XCTAssertEqual(editor.string, "test-key-placeholder")
        try command("a")
        try command("v")
        XCTAssertEqual(editor.string, "test-key-placeholder")
        window.makeFirstResponder(nil)
        XCTAssertEqual(field.stringValue, "test-key-placeholder")
    }
    func testOutputOptionsPersistIndependently() throws {
        let name = "vibeboardplus.settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.outputMode, .pasteOnCompletion)
        XCTAssertTrue(settings.autoCopy)
        settings.outputMode = .overlay
        settings.autoCopy = false
        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.outputMode, .overlay)
        XCTAssertFalse(restored.autoCopy)
        settings.outputMode = .liveInput
        XCTAssertFalse(settings.autoCopy)
        XCTAssertEqual(settings.asrModel, "stepaudio-2.5-asr-stream")
        settings.rewriteEngine = "local"
        XCTAssertEqual(restored.rewriteEngine, "local")
        settings.rewriteEngine = "cloud"
        settings.asrProvider = "stepfun"
        XCTAssertEqual(restored.rewriteEngine, "cloud")
        XCTAssertEqual(restored.asrProvider, "stepfun")
    }

    func testExistingDisabledInputPreferenceIsPreserved() throws {
        let name = "vibeboardplus.settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "automaticInput")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.outputMode, .overlay)
        settings.outputMode = .pasteOnCompletion
        XCTAssertEqual(settings.outputMode, .pasteOnCompletion)
    }

    @MainActor
    func testSavingRecognitionPreservesRewriteDraft() throws {
        _ = NSApplication.shared
        let name = "vibeboardplus.settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let rewriteBefore = settings.rewrite
        let controller = MainWindowController(settings: settings, buttons: ButtonSettings())
        let window = try XCTUnwrap(controller.window)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(try XCTUnwrap(window.contentView))
        let model = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.isEditable && !($0 is NSSecureTextField) })
        model.stringValue = "unsaved-rewrite-model"
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        let save = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "保存识别配置" })
        save.performClick(nil)
        XCTAssertEqual(model.stringValue, "unsaved-rewrite-model")
        XCTAssertEqual(settings.rewriteModel, "step-3.5-flash")
        XCTAssertEqual(settings.rewrite, rewriteBefore)
    }

    @MainActor
    func testMainWindowSectionsAndLayout() throws {
        _ = NSApplication.shared
        let controller = MainWindowController(settings: AppSettings(), buttons: ButtonSettings())
        XCTAssertEqual(controller.sectionTitles,
                       ["概览", "语音识别", "模型管理", "设备按键", "输出", "语义整理", "关于"])

        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()

        func check(_ view: NSView, in bounds: NSRect) {
            guard !view.isHidden else { return }
            if view is NSControl, view.bounds.width > 0 {
                let rect = view.convert(view.bounds, to: nil)
                // 横向不能超出窗口，纵向允许滚动。
                XCTAssertGreaterThanOrEqual(rect.minX, -2, "Control starts left of the window: \(view)")
                XCTAssertLessThanOrEqual(rect.maxX, content.bounds.width + 2, "Control clipped on the right: \(view)")
            }
            for child in view.subviews { check(child, in: bounds) }
        }

        for index in 0..<controller.sectionTitles.count {
            controller.selectSection(index)
            content.layoutSubtreeIfNeeded()
            for page in controller.pageViews { check(page, in: content.bounds) }
            if index == 2 {
                // 模型管理页应当渲染出模型卡片（至少内置目录里的模型）。
                let texts = controller.pageViews.flatMap { view -> [String] in
                    func collect(_ view: NSView) -> [String] {
                        (view as? NSTextField).map { [$0.stringValue] } ?? [] + view.subviews.flatMap(collect)
                    }
                    return collect(view)
                }
                XCTAssertTrue(texts.contains { $0.contains("当前使用") }, "model page should show the active model")
            }
        }

        let snapshot = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: snapshot)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vibeboardplus-main.png")
        try XCTUnwrap(snapshot.representation(using: .png, properties: [:])).write(to: url)
        print("Settings snapshot: \(url.path)")
    }
}
