import AppKit

enum OutputMode: String, CaseIterable {
    case overlay, liveInput, pasteOnCompletion
    var title: String {
        switch self {
        case .overlay: return "仅悬浮窗"
        case .liveInput: return "实时输入到输入框"
        case .pasteOnCompletion: return "完成后粘贴到输入框"
        }
    }
}

final class AppSettings {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var asrProvider: String {
        get { defaults.string(forKey: "asrProvider") ?? "apple" }
        set { defaults.set(newValue, forKey: "asrProvider") }
    }
    var asrModel: String {
        get { defaults.string(forKey: "cloudASRModel") ?? "stepaudio-2.5-asr-stream" }
        set { defaults.set(newValue, forKey: "cloudASRModel") }
    }
    var rewriteModel: String {
        get { defaults.string(forKey: "cloudRewriteModel") ?? "step-3.5-flash" }
        set { defaults.set(newValue, forKey: "cloudRewriteModel") }
    }
    var rewriteEngine: String {
        get { defaults.string(forKey: "rewriteEngine") ?? "cloud" }
        set { defaults.set(newValue, forKey: "rewriteEngine") }
    }
    var outputMode: OutputMode {
        get {
            if let value = defaults.string(forKey: "outputMode"), let mode = OutputMode(rawValue: value) { return mode }
            return defaults.object(forKey: "automaticInput") != nil && !defaults.bool(forKey: "automaticInput") ? .overlay : .pasteOnCompletion
        }
        set { defaults.set(newValue.rawValue, forKey: "outputMode") }
    }
    var autoCopy: Bool {
        get { defaults.object(forKey: "autoCopyResult") == nil || defaults.bool(forKey: "autoCopyResult") }
        set { defaults.set(newValue, forKey: "autoCopyResult") }
    }
    var rewrite: Bool {
        get { defaults.bool(forKey: "semanticRewrite") }
        set { defaults.set(newValue, forKey: "semanticRewrite") }
    }
}

final class SettingsEditingWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        if modifiers == .command, let editor = firstResponder as? NSTextView {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v": editor.paste(nil); return true
            case "c": editor.copy(nil); return true
            case "x": editor.cut(nil); return true
            case "a": editor.selectAll(nil); return true
            case "z": editor.undoManager?.undo(); return true
            default: break
            }
        }
        if modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z",
           let editor = firstResponder as? NSTextView {
            editor.undoManager?.redo(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class SettingsWindow: NSWindowController {
    private let settings: AppSettings
    private let buttons: ButtonSettings
    private let mode = NSPopUpButton()
    private let autoCopy = NSSwitch()
    private let rewrite = NSSwitch()
    private let rewriteEngine = NSPopUpButton()
    private let provider = NSPopUpButton()
    private let asrModel = NSPopUpButton()
    private let rewriteModel = NSTextField(string: "")
    private let recognitionKey = NSSecureTextField(string: "")
    private let rewriteKey = NSSecureTextField(string: "")
    private let recognitionStatus = NSTextField(labelWithString: "")
    private let rewriteStatus = NSTextField(labelWithString: "")
    private var connectionTask: Task<Void, Never>?
    private let permissionStatus = NSTextField(labelWithString: "")
    private var choices: [String: NSPopUpButton] = [:]
    private let tabs = NSSegmentedControl(labels: ["识别输出", "设备按键", "权限", "语音识别", "语义整理"], trackingMode: .selectOne, target: nil, action: nil)
    private var pages: [NSStackView] = []
    private var observer: NSObjectProtocol?

    init(settings: AppSettings, buttons: ButtonSettings) {
        self.settings = settings
        self.buttons = buttons
        let window = SettingsEditingWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "VibeBoard Plus 设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let content = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 560, height: 440))
        content.material = .windowBackground
        content.blendingMode = .behindWindow
        content.state = .active
        window.contentView = content
        tabs.target = self
        tabs.action = #selector(changeTab)
        tabs.selectedSegment = 0
        tabs.segmentStyle = .rounded
        tabs.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            tabs.widthAnchor.constraint(equalToConstant: 496)
        ])
        for title in ["识别输出", "设备按键", "权限与服务", "语音识别", "语义整理"] {
            let page = NSStackView()
            page.orientation = .vertical
            page.alignment = .leading
            page.spacing = 20
            page.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(page)
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
                page.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
                page.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 32)
            ])
            let heading = NSTextField(labelWithString: title)
            heading.font = .systemFont(ofSize: 20, weight: .semibold)
            page.addArrangedSubview(heading)
            pages.append(page)
        }
        mode.addItems(withTitles: OutputMode.allCases.map(\.title))
        mode.target = self; mode.action = #selector(changeOutput)
        addRow("输出方式", control: mode, page: pages[0])
        autoCopy.target = self; autoCopy.action = #selector(changeOutput)
        addRow("完成后自动复制", control: autoCopy, page: pages[0])
        rewrite.target = self; rewrite.action = #selector(saveRewrite)
        addRow("轻度语义整理", control: rewrite, page: pages[4])
        rewriteEngine.addItems(withTitles: ["云端 · StepFun", "本地 · Apple"])
        rewriteEngine.target = self; rewriteEngine.action = #selector(saveRewrite)
        addRow("整理引擎", control: rewriteEngine, page: pages[4])
        for name in ButtonSettings.buttons {
            let popup = NSPopUpButton()
            popup.addItems(withTitles: ButtonAction.allCases.map(\.title))
            popup.target = self; popup.action = #selector(changeButtons)
            choices[name] = popup
            addRow(name.uppercased(), control: popup, page: pages[1])
        }
        permissionStatus.font = .systemFont(ofSize: 13)
        permissionStatus.textColor = .secondaryLabelColor
        permissionStatus.maximumNumberOfLines = 3
        pages[2].addArrangedSubview(permissionStatus)
        let speech = NSButton(title: "授权语音识别", target: self, action: #selector(authorizeSpeech))
        speech.bezelStyle = .rounded
        let access = NSButton(title: "授权辅助功能", target: self, action: #selector(authorizeAccess))
        access.bezelStyle = .rounded
        pages[2].addArrangedSubview(NSStackView(views: [speech, access]))
        pages[3].spacing = 12
        pages[4].spacing = 12
        provider.addItems(withTitles: ["Apple 语音识别", "StepFun 官方 API", "旧版官方中转（未就绪）"])
        provider.autoenablesItems = false
        provider.item(at: 2)?.isEnabled = false
        provider.target = self; provider.action = #selector(saveRecognition)
        addRow("识别服务", control: provider, page: pages[3])
        asrModel.addItems(withTitles: ["stepaudio-2.5-asr-stream", "step-asr-1.1-stream", "stepaudio-2.5-asr", "step-asr"])
        asrModel.target = self; asrModel.action = #selector(saveRecognition)
        addRow("语音模型", control: asrModel, page: pages[3])
        rewriteModel.widthAnchor.constraint(equalToConstant: 290).isActive = true
        rewriteModel.target = self; rewriteModel.action = #selector(saveRewrite)
        addRow("整理模型", control: rewriteModel, page: pages[4])
        for (field, page, name) in [(recognitionKey, pages[3], "recognition-key"), (rewriteKey, pages[4], "rewrite-key")] {
            field.widthAnchor.constraint(equalToConstant: 290).isActive = true
            field.identifier = NSUserInterfaceItemIdentifier(name)
            field.placeholderString = "StepFun API Key"
            addRow("API Key", control: field, page: page)
        }
        let saveRecognition = NSButton(title: "保存识别配置", target: self, action: #selector(saveRecognition))
        saveRecognition.bezelStyle = .rounded
        pages[3].addArrangedSubview(saveRecognition)
        let save = NSButton(title: "保存整理配置", target: self, action: #selector(saveRewrite))
        let test = NSButton(title: "测试云端整理", target: self, action: #selector(testCloud))
        save.bezelStyle = .rounded; test.bezelStyle = .rounded
        pages[4].addArrangedSubview(NSStackView(views: [save, test]))
        for (status, page) in [(recognitionStatus, pages[3]), (rewriteStatus, pages[4])] {
            status.font = .systemFont(ofSize: 12)
            status.textColor = .secondaryLabelColor
            status.maximumNumberOfLines = 2
            status.widthAnchor.constraint(equalToConstant: 490).isActive = true
            page.addArrangedSubview(status)
        }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                         object: window, queue: .main) { [weak self] _ in self?.refreshStatus() }
        refresh()
        changeTab()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private func addRow(_ title: String, control: NSView, page: NSStackView) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.widthAnchor.constraint(equalToConstant: 168).isActive = true
        control.setAccessibilityLabel(title)
        let row = NSStackView(views: [label, control])
        row.spacing = 16
        row.alignment = .centerY
        page.addArrangedSubview(row)
        if control is NSPopUpButton { control.widthAnchor.constraint(equalToConstant: 290).isActive = true }
    }

    func present() {
        refreshStatus()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    private func refresh() {
        mode.selectItem(withTitle: settings.outputMode.title)
        autoCopy.state = settings.autoCopy ? .on : .off
        rewrite.isEnabled = true
        rewrite.state = settings.rewrite ? .on : .off
        rewrite.toolTip = "纠错、标点、去重复，保持原意"
        rewriteEngine.selectItem(at: settings.rewriteEngine == "local" ? 1 : 0)
        rewriteEngine.item(at: 1)?.title = SemanticRewriter.localIsAvailable ? "本地 · Apple" : "本地 · Apple（不可用）"
        provider.selectItem(at: ["apple", "stepfun", "relay"].firstIndex(of: settings.asrProvider) ?? 0)
        asrModel.selectItem(withTitle: settings.asrModel)
        rewriteModel.stringValue = settings.rewriteModel
        for (name, popup) in choices { popup.selectItem(withTitle: buttons.action(for: name).title) }
        refreshStatus()
    }
    private func refreshStatus() {
        recognitionKey.placeholderString = CloudKey.read(for: .recognition).isEmpty ? "StepFun API Key" : "已保存；输入新密钥可替换"
        rewriteKey.placeholderString = CloudKey.read(for: .rewrite).isEmpty ? "StepFun API Key" : "已保存；输入新密钥可替换"
        rewriteEngine.item(at: 1)?.title = SemanticRewriter.localIsAvailable ? "本地 · Apple" : "本地 · Apple（不可用）"
        permissionStatus.stringValue = "语音识别：\(AppleSpeechProvider.isAuthorized ? "已授权" : "未授权")\n辅助功能：\(AXIsProcessTrusted() ? "已授权" : "未授权")"
    }
    @objc private func changeTab() {
        window?.makeFirstResponder(nil)
        for (index, page) in pages.enumerated() { page.isHidden = index != tabs.selectedSegment }
    }
    @objc private func changeOutput() {
        settings.outputMode = OutputMode.allCases[mode.indexOfSelectedItem]
        settings.autoCopy = autoCopy.state == .on
    }
    @objc private func changeButtons() { buttons.save(choices.mapValues { ButtonAction.allCases[$0.indexOfSelectedItem] }) }
    private func saveKey(_ field: NSSecureTextField, purpose: CloudKey.Purpose, status: NSTextField) -> Bool {
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            guard CloudKey.save(key, for: purpose) else { status.stringValue = "密钥保存失败，请检查钥匙串访问权限"; return false }
            field.stringValue = ""
        }
        return true
    }
    @objc private func saveRecognition() {
        guard saveKey(recognitionKey, purpose: .recognition, status: recognitionStatus) else { return }
        settings.asrProvider = ["apple", "stepfun", "relay"][provider.indexOfSelectedItem]
        settings.asrModel = asrModel.titleOfSelectedItem ?? "stepaudio-2.5-asr-stream"
        recognitionStatus.stringValue = "识别配置已保存，下次录音生效"
        refreshStatus()
    }
    @objc private func saveRewrite() { _ = persistRewrite() }
    private func persistRewrite() -> Bool {
        guard saveKey(rewriteKey, purpose: .rewrite, status: rewriteStatus) else { return false }
        connectionTask?.cancel()
        settings.rewrite = rewrite.state == .on
        settings.rewriteEngine = rewriteEngine.indexOfSelectedItem == 1 ? "local" : "cloud"
        let model = rewriteModel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty { settings.rewriteModel = model }
        rewriteStatus.stringValue = "整理配置已保存"
        refreshStatus()
        return true
    }
    @objc private func testCloud() {
        guard persistRewrite() else { return }
        connectionTask?.cancel()
        rewriteStatus.stringValue = "正在测试…"
        let model = settings.rewriteModel
        let client = CloudService(key: CloudKey.read(for: .rewrite))
        connectionTask = Task { @MainActor [weak self] in
            do {
                _ = try await client.rewrite("你好你好今天下午三点开会", model: model)
                try Task.checkCancellation()
                self?.rewriteStatus.stringValue = "云端整理连接成功"
            } catch {
                guard !Task.isCancelled else { return }
                self?.rewriteStatus.stringValue = (error as? SemanticRewriteError)?.errorDescription ?? "连接失败，请检查网络"
            }
        }
    }
    @objc private func authorizeSpeech() {
        AppleSpeechProvider.requestAuthorization { _ in DispatchQueue.main.async { self.refreshStatus() } }
    }
    @objc private func authorizeAccess() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        refreshStatus()
    }
}
