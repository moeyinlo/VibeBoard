import AppKit
import XCTest
@testable import VibeBoardPlus

final class AppSettingsTests: XCTestCase {
    @MainActor
    func testSecureFieldPastesAndReplacesSelection() throws {
        _ = NSApplication.shared
        let window = SettingsEditingWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
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
    func testSavingRecognitionAndRefocusingPreserveRewriteDraft() throws {
        _ = NSApplication.shared
        let name = "vibeboardplus.settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let controller = SettingsWindow(settings: settings, buttons: ButtonSettings())
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
        XCTAssertFalse(settings.rewrite)
    }

    @MainActor
    func testSettingsWindowLayout() throws {
        _ = NSApplication.shared
        let controller = SettingsWindow(settings: AppSettings(), buttons: ButtonSettings())
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        func check(_ view: NSView) {
            guard !view.isHidden else { return }
            if view is NSControl {
                let rect = view.convert(view.bounds, to: content)
                XCTAssertTrue(content.bounds.insetBy(dx: -1, dy: -1).contains(rect), "Clipped control: \(view)")
            }
            for child in view.subviews { check(child) }
        }
        let tabs = try XCTUnwrap(content.subviews.compactMap { $0 as? NSSegmentedControl }.first)
        XCTAssertEqual(tabs.segmentCount, 5)
        XCTAssertEqual(tabs.label(forSegment: 3), "语音识别")
        XCTAssertEqual(tabs.label(forSegment: 4), "语义整理")
        for index in 0..<tabs.segmentCount {
            tabs.selectedSegment = index
            tabs.sendAction(tabs.action, to: tabs.target)
            content.layoutSubtreeIfNeeded()
            check(content)
            if index >= 3 {
                let snapshot = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: snapshot)
                let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vibeboardplus-settings-\(index).png")
                try XCTUnwrap(snapshot.representation(using: .png, properties: [:])).write(to: url)
            }
        }
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let image = NSImage(size: content.bounds.size)
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        content.bounds.fill()
        bitmap.draw(in: content.bounds)
        image.unlockFocus()
        let composite = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        let data = try XCTUnwrap(composite.representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vibeboardplus-settings.png")
        try data.write(to: url)
        print("Settings snapshot: \(url.path)")
    }
}
