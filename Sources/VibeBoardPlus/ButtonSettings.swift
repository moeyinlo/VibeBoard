import AppKit

enum ButtonAction: String, CaseIterable {
    case voice, toggleVoice, copyResult, showResult, cancel, paste, undo, enter, escape, none

    var title: String {
        switch self {
        case .voice: return "按住说话"
        case .toggleVoice: return "切换录音"
        case .copyResult: return "复制识别结果"
        case .showResult: return "显示最近结果"
        case .cancel: return "取消识别"
        case .paste: return "粘贴 (Command+V)"
        case .undo: return "撤销 (Command+Z)"
        case .enter: return "回车"
        case .escape: return "Escape"
        case .none: return "不执行动作"
        }
    }
}

final class ButtonSettings {
    static let buttons = ["k1", "k2", "k3", "k4"]
    private let defaults: UserDefaults
    private let key = "buttonActions.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func action(for button: String) -> ButtonAction {
        guard Self.buttons.contains(button.lowercased()) else { return .none }
        let values = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        return values[button.lowercased()].flatMap(ButtonAction.init(rawValue:)) ?? .voice
    }
    func save(_ actions: [String: ButtonAction]) {
        defaults.set(actions.filter { Self.buttons.contains($0.key) }.mapValues(\.rawValue), forKey: key)
    }
}

struct ButtonEventRouter {
    enum Command: Equatable {
        case start(UInt64), finish, toggle(UInt64), action(ButtonAction)
    }
    private var pressed: [String: ButtonAction] = [:]
    private var released: [String: TimeInterval] = [:]

    mutating func down(_ button: String, session: UInt64, action: ButtonAction) -> Command? {
        guard pressed[button] == nil else { return nil }
        pressed[button] = action
        switch action {
        case .voice: return .start(session)
        case .toggleVoice: return .toggle(session)
        case .none: return nil
        default: return .action(action)
        }
    }
    mutating func up(_ button: String, now: TimeInterval) -> Command? {
        guard let action = pressed.removeValue(forKey: button) else { return nil }
        released[button] = now
        return action == .voice ? .finish : nil
    }
    mutating func click(_ button: String, action: ButtonAction, now: TimeInterval) -> Command? {
        // Some firmware emits a click after the down/up pair. Execute each press once.
        guard pressed[button] == nil, now - (released[button] ?? -.infinity) > 0.5 else { return nil }
        switch action {
        case .voice, .toggleVoice: return .toggle(0)
        case .none: return nil
        default: return .action(action)
        }
    }
}

final class ButtonSettingsWindow: NSWindowController {
    private let settings: ButtonSettings
    private var choices: [String: NSPopUpButton] = [:]

    init(settings: ButtonSettings) {
        self.settings = settings
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 310),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "按键设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)
        ])
        for button in ButtonSettings.buttons {
            let label = NSTextField(labelWithString: button.uppercased())
            label.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
            label.widthAnchor.constraint(equalToConstant: 56).isActive = true
            let popup = NSPopUpButton()
            popup.addItems(withTitles: ButtonAction.allCases.map(\.title))
            popup.setAccessibilityLabel("\(button.uppercased()) 的动作")
            choices[button] = popup
            let row = NSStackView(views: [label, popup])
            row.spacing = 16
            row.alignment = .centerY
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let save = NSButton(title: "保存", target: self, action: #selector(saveSettings))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelSettings))
        cancel.bezelStyle = .rounded
        let row = NSStackView(views: [cancel, save])
        row.spacing = 12
        stack.addArrangedSubview(row)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() {
        for (button, popup) in choices { popup.selectItem(withTitle: settings.action(for: button).title) }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    @objc private func saveSettings() {
        settings.save(choices.mapValues { ButtonAction.allCases[$0.indexOfSelectedItem] })
        close()
    }
    @objc private func cancelSettings() { close() }
}
