import AppKit
import ApplicationServices

final class KeyboardActionSender {
    private var lastExternalApp: NSRunningApplication?
    private var observer: NSObjectProtocol?
    private var permissionPrompted = false
    var onStatus: ((String) -> Void)?

    init() {
        remember(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            self?.remember(notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    private func remember(_ app: NSRunningApplication?) {
        if let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalApp = app
        }
    }

    static func events(for action: ButtonAction) -> [CGEvent] {
        let key: CGKeyCode
        let flags: CGEventFlags
        switch action {
        case .paste: key = 9; flags = .maskCommand
        case .undo: key = 6; flags = .maskCommand
        case .enter: key = 36; flags = []
        case .escape: key = 53; flags = []
        default: return []
        }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return [] }
        for event in [down, up] {
            event.flags = flags
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        }
        return [down, up]
    }

    func send(_ action: ButtonAction) {
        let allowed = CGPreflightPostEventAccess()
        vlog("[keyboard] action=\(action.rawValue) post_allowed=\(allowed) ax_trusted=\(AXIsProcessTrusted())")
        guard allowed else {
            onStatus?("请在系统设置中允许 VibeBoard Plus 使用辅助功能")
            if !permissionPrompted {
                permissionPrompted = true
                _ = CGRequestPostEventAccess()
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        let target = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? lastExternalApp : front
        guard let target, !target.isTerminated else {
            onStatus?("请先选中目标应用的输入框")
            return
        }
        if target.processIdentifier != front?.processIdentifier {
            target.activate(options: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.post(action, to: target)
            }
        } else {
            post(action, to: target)
        }
    }

    private func post(_ action: ButtonAction, to target: NSRunningApplication) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
            onStatus?("目标应用已改变，请重新按键")
            return
        }
        let events = Self.events(for: action)
        guard events.count == 2 else { onStatus?("无法创建键盘事件"); return }
        for event in events { event.post(tap: .cghidEventTap) }
        vlog("[keyboard] posted action=\(action.rawValue) target=\(target.bundleIdentifier ?? "unknown")")
        onStatus?("已发送：\(action.title)")
    }
}
