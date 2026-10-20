import AppKit
import ApplicationServices

struct TranscriptReplacement {
    let original: String
    let selection: NSRange
    private(set) var inserted = ""

    var currentValue: String {
        (original as NSString).replacingCharacters(in: selection, with: inserted)
    }
    var caret: NSRange { NSRange(location: selection.location + inserted.utf16.count, length: 0) }
    var replacementRange: NSRange { NSRange(location: selection.location, length: inserted.utf16.count) }

    mutating func update(_ text: String) { inserted = text }
}

final class FocusedTextOutput {
    private let element: AXUIElement
    private let pid: pid_t
    private var draft: TranscriptReplacement
    private var first = true

    fileprivate static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    fileprivate static func focusedElement() -> AXUIElement? {
        guard let value = attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    fileprivate static func selectedRange(_ element: AXUIElement) -> NSRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    init?() {
        guard AXIsProcessTrusted(), let element = Self.focusedElement(),
              let role = Self.attribute(element, kAXRoleAttribute) as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
              Self.attribute(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole,
              let original = Self.attribute(element, kAXValueAttribute) as? String,
              let selection = Self.selectedRange(element),
              selection.location >= 0, selection.length >= 0,
              selection.location <= original.utf16.count,
              selection.length <= original.utf16.count - selection.location else { return nil }
        var textSettable = DarwinBoolean(false)
        var rangeSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &textSettable) == .success,
              AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &rangeSettable) == .success,
              textSettable.boolValue, rangeSettable.boolValue else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        self.element = element
        self.pid = pid
        draft = TranscriptReplacement(original: original, selection: selection)
    }

    func update(_ text: String) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let focused = Self.focusedElement(), CFEqual(element, focused),
              let value = Self.attribute(element, kAXValueAttribute) as? String,
              value == (first ? draft.original : draft.currentValue),
              Self.selectedRange(element) == (first ? draft.selection : draft.caret) else { return false }
        if !first, text == draft.inserted { return true }
        // Only replace this dictation's range, and stop if the user edits or moves the caret.
        let replacement = first ? draft.selection : draft.replacementRange
        var range = CFRange(location: replacement.location, length: replacement.length)
        guard let rangeValue = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue) == .success else { return false }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
            var previous = CFRange(location: replacement.location + replacement.length, length: 0)
            if let value = AXValueCreate(.cfRange, &previous) {
                _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
            }
            return false
        }
        draft.update(text)
        first = false
        var caret = CFRange(location: draft.caret.location, length: 0)
        if let value = AXValueCreate(.cfRange, &caret) {
            _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
        }
        return true
    }
}

final class FocusedPasteTarget {
    private let element: AXUIElement
    private let pid: pid_t
    private let original: String?
    private let selection: NSRange?

    init?() {
        guard AXIsProcessTrusted(), let element = FocusedTextOutput.focusedElement(),
              let role = FocusedTextOutput.attribute(element, kAXRoleAttribute) as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
              FocusedTextOutput.attribute(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        self.element = element
        self.pid = pid
        original = FocusedTextOutput.attribute(element, kAXValueAttribute) as? String
        selection = FocusedTextOutput.selectedRange(element)
    }

    func paste(_ text: String, keepClipboard: Bool) -> Bool {
        guard CGPreflightPostEventAccess(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let focused = FocusedTextOutput.focusedElement(), CFEqual(element, focused),
              FocusedTextOutput.attribute(element, kAXValueAttribute) as? String == original,
              FocusedTextOutput.selectedRange(element) == selection else { return false }
        let events = KeyboardActionSender.events(for: .paste)
        guard events.count == 2 else { return false }
        let board = NSPasteboard.general
        let previous: [NSPasteboardItem] = keepClipboard ? [] : (board.pasteboardItems ?? []).map { item in
            let snapshot = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { snapshot.setData(data, forType: type) } }
            return snapshot
        }
        board.clearContents()
        guard board.setString(text, forType: .string) else { return false }
        let change = board.changeCount
        for event in events { event.post(tap: .cghidEventTap) }
        if !keepClipboard {
            // Give the receiving app time to read the pasteboard; never undo a later user copy.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard board.changeCount == change else { return }
                board.clearContents()
                if !previous.isEmpty { board.writeObjects(previous) }
            }
        }
        vlog("[output] pasted final transcript target_pid=\(pid)")
        return true
    }
}

final class RecognitionOverlay {
    let panel: NSPanel
    private let status = NSTextField(labelWithString: "正在聆听")
    private let transcript = NSTextView()
    private let scroll = NSScrollView()
    private let indicator = NSImageView()
    private let copy = NSButton()
    private var copyFeedbackWork: DispatchWorkItem?
    private var scrollHeight: NSLayoutConstraint!
    private var hideWork: DispatchWorkItem?
    private var dismissedForSession = false

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 104),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.setAccessibilityLabel("VibeBoard Plus 识别文字")
        let content = NSVisualEffectView()
        content.material = .popover
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 8
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 0.5
        content.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = content
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        indicator.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "语音识别")
        indicator.contentTintColor = .systemTeal
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭")!,
                             target: self, action: #selector(closeForSession))
        close.isBordered = false
        close.toolTip = "关闭"
        close.contentTintColor = .secondaryLabelColor
        close.imageScaling = .scaleProportionallyDown
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "复制")
        copy.title = ""
        copy.target = self
        copy.action = #selector(copyText)
        copy.isBordered = false
        copy.toolTip = "复制识别文字"
        copy.contentTintColor = .secondaryLabelColor
        copy.imageScaling = .scaleProportionallyDown
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.drawsBackground = false
        transcript.font = .systemFont(ofSize: 19, weight: .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        transcript.defaultParagraphStyle = paragraph
        transcript.textColor = .labelColor
        transcript.isHorizontallyResizable = false
        transcript.isVerticallyResizable = true
        transcript.minSize = NSSize(width: 0, height: 0)
        transcript.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        transcript.textContainer?.containerSize = NSSize(width: 428, height: CGFloat.greatestFiniteMagnitude)
        transcript.autoresizingMask = [.width]
        transcript.textContainer?.widthTracksTextView = true
        transcript.textContainerInset = NSSize(width: 0, height: 0)
        transcript.textContainer?.lineFragmentPadding = 0
        scroll.documentView = transcript
        for view in [indicator, status, close, copy, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            indicator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            indicator.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 18), indicator.heightAnchor.constraint(equalToConstant: 18),
            status.leadingAnchor.constraint(equalTo: indicator.trailingAnchor, constant: 8),
            status.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            status.trailingAnchor.constraint(lessThanOrEqualTo: copy.leadingAnchor, constant: -8),
            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            close.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 24), close.heightAnchor.constraint(equalToConstant: 24),
            copy.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -6),
            copy.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            copy.widthAnchor.constraint(equalToConstant: 24), copy.heightAnchor.constraint(equalToConstant: 24),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 48)
        ])
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 36)
        scrollHeight.isActive = true
    }

    func beginSession() {
        dismiss()
        resetCopyFeedback()
        dismissedForSession = false
    }

    func render(_ text: String, final: Bool) {
        if text != transcript.string { resetCopyFeedback() }
        copy.isEnabled = !text.isEmpty
        status.stringValue = final ? (text.isEmpty ? "未识别到文字" : "识别完成") : "正在聆听"
        indicator.image = NSImage(systemSymbolName: final ? "checkmark.circle.fill" : "waveform", accessibilityDescription: status.stringValue)
        indicator.contentTintColor = final ? .systemGreen : .systemTeal
        panel.contentView?.layoutSubtreeIfNeeded()
        let width = max(1, panel.frame.width - 40)
        transcript.setFrameSize(NSSize(width: width, height: 36))
        transcript.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        transcript.string = text
        transcript.layoutManager?.ensureLayout(for: transcript.textContainer!)
        let used = transcript.layoutManager?.usedRect(for: transcript.textContainer!).height ?? 36
        let height = text.isEmpty ? 0 : min(180, max(30, ceil(used)))
        scrollHeight.constant = height
        scroll.isHidden = text.isEmpty
        var frame = panel.frame
        frame.size.height = text.isEmpty ? 56 : height + 68
        panel.setFrame(frame, display: true)
        panel.contentView?.layoutSubtreeIfNeeded()
        transcript.sizeToFit()
        transcript.scrollRangeToVisible(NSRange(location: text.utf16.count, length: 0))
    }

    func show(_ text: String, final: Bool = false) {
        guard !dismissedForSession else { return }
        hideWork?.cancel()
        if !panel.isVisible {
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                let width = min(460, frame.width - 32)
                panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.minY + 64, width: width, height: 104), display: true)
            }
            panel.orderFrontRegardless()
        }
        render(text, final: final)
        if final {
            let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
        }
    }

    func finishStatus(_ text: String) { if panel.isVisible { status.stringValue = text } }
    @objc private func closeForSession() { dismissedForSession = true; dismiss() }
    @objc func dismiss() { hideWork?.cancel(); panel.orderOut(nil) }
    @objc private func copyText() {
        guard !transcript.string.isEmpty else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(transcript.string, forType: .string) else { return }
        copyFeedbackWork?.cancel()
        copy.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "已复制")
        copy.contentTintColor = .systemGreen
        copy.toolTip = "已复制"
        copy.setAccessibilityLabel("已复制")
        let work = DispatchWorkItem { [weak self] in self?.resetCopyFeedback() }
        copyFeedbackWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func resetCopyFeedback() {
        copyFeedbackWork?.cancel()
        copyFeedbackWork = nil
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "复制")
        copy.contentTintColor = .secondaryLabelColor
        copy.toolTip = "复制识别文字"
        copy.setAccessibilityLabel("复制识别文字")
    }
}

final class RecognitionOutput {
    private let overlay = RecognitionOverlay()
    private var input: FocusedTextOutput?
    private var active = false
    private var lastText = ""
    private var pasteTarget: FocusedPasteTarget?
    private var autoCopy = false

    func begin(mode: OutputMode, autoCopy: Bool) {
        active = true
        lastText = ""
        self.autoCopy = autoCopy
        input = mode == .liveInput ? FocusedTextOutput() : nil
        pasteTarget = mode == .pasteOnCompletion ? FocusedPasteTarget() : nil
        overlay.beginSession()
        if input == nil { overlay.show("") }
    }

    func receive(_ text: String, final: Bool) {
        guard active else { return }
        // An error/timeout must not erase a partial transcript already inserted.
        let displayed = final && text.isEmpty ? lastText : text
        lastText = displayed
        if final, !displayed.isEmpty, autoCopy {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(displayed, forType: .string)
        }
        if final, !displayed.isEmpty, let pasteTarget, pasteTarget.paste(displayed, keepClipboard: autoCopy) {
            overlay.dismiss()
        } else if let input, !displayed.isEmpty, input.update(displayed) {
            overlay.dismiss()
        } else {
            input = nil
            overlay.show(displayed, final: final)
        }
        if final { active = false; input = nil; pasteTarget = nil }
    }

    func status(_ text: String) { overlay.finishStatus(text) }
    func showLatest(_ text: String) {
        guard !active else { return }
        overlay.beginSession()
        overlay.show(text, final: true)
    }
    func cancel() { active = false; input = nil; pasteTarget = nil; overlay.dismiss() }
}
