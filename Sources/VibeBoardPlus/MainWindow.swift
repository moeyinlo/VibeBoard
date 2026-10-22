import AppKit
import UniformTypeIdentifiers

/// 主窗口（设置 + 状态 + 模型管理）。
///
/// 结构：左侧栏导航（NSSplitViewController + source list），右侧内容区。
/// 之前的小设置面板完全被替换。
/// 非翻转的 NSView 会把内容锚在左下角；滚动页需要从顶部开始。
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class MainWindow: NSWindow {
    /// 让设置里的文本域支持原生 Command-V/C/Z。
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

// MARK: - 左侧栏

private final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let titles: [String]
    private let table = NSTableView()
    var onSelect: ((Int) -> Void)?

    init(titles: [String]) {
        self.titles = titles
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 30
        table.dataSource = self
        table.delegate = self
        table.focusRingType = .none

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        view = scroll
    }

    func select(row: Int) {
        guard row >= 0, row < titles.count else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { titles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("sidebar-cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .systemFont(ofSize: 13, weight: .medium)
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.textField?.stringValue = titles[row]
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelect?(table.selectedRow)
    }
}

// MARK: - 主窗口

final class MainWindowController: NSWindowController {
    private enum Section: Int, CaseIterable {
        case overview, speech, models, buttons, output, rewrite, about
        var title: String {
            switch self {
            case .overview: return "概览"
            case .speech: return "语音识别"
            case .models: return "模型管理"
            case .buttons: return "设备按键"
            case .output: return "输出"
            case .rewrite: return "语义整理"
            case .about: return "关于"
            }
        }
    }

    private let settings: AppSettings
    private let buttons: ButtonSettings
    private let sidebar: SidebarViewController
    private let container = NSView()
    private var pages: [Section: NSView] = [:]
    private var currentSection: Section = .overview

    // 概览
    private let overviewStatus = NSTextField(labelWithString: "等待设备")
    private let overviewBackend = NSTextField(labelWithString: "")
    private let overviewStats = NSTextField(labelWithString: "")
    private let lastText = NSTextView()
    private let lastTextScroll = NSScrollView()
    private let lastTextPlaceholder = NSTextField(labelWithString: "识别结果会显示在这里")

    // 语音识别
    private let provider = NSPopUpButton()
    private let asrModel = NSPopUpButton()
    private let recognitionKey = NSSecureTextField(string: "")
    private let recognitionStatus = NSTextField(labelWithString: "")

    // 模型管理
    private let modelList = NSStackView()
    private let modelStatus = NSTextField(labelWithString: "")
    private let modelProgress = NSProgressIndicator()
    private let activeModelLabel = NSTextField(labelWithString: "")
    private var downloadInFlight = false

    // 按键 / 输出 / 整理
    private var buttonChoices: [String: NSPopUpButton] = [:]
    private let mode = NSPopUpButton()
    private let autoCopy = NSSwitch()
    private let rewrite = NSSwitch()
    private let rewriteEngine = NSPopUpButton()
    private let rewriteModel = NSTextField(string: "")
    private let rewriteKey = NSSecureTextField(string: "")
    private let rewriteStatus = NSTextField(labelWithString: "")
    private var connectionTask: Task<Void, Never>?

    // 关于
    private let permissionStatus = NSTextField(labelWithString: "")

    private var observers: [NSObjectProtocol] = []

    var statusProvider: () -> String = { "等待设备" }
    var latestTextProvider: () -> String = { "" }
    var onCancel: (() -> Void)?

    init(settings: AppSettings, buttons: ButtonSettings) {
        self.settings = settings
        self.buttons = buttons
        self.sidebar = SidebarViewController(titles: Section.allCases.map(\.title))
        let window = MainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VibeBoard Plus"
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.minSize = NSSize(width: 820, height: 600)
        super.init(window: window)

        let detail = NSViewController()
        detail.view = container
        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 170
        sidebarItem.maximumThickness = 220
        sidebarItem.canCollapse = false
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: detail))
        window.contentViewController = split

        sidebar.onSelect = { [weak self] row in
            guard let self, let section = Section(rawValue: row) else { return }
            self.show(section)
        }

        buildPages()
        let initial = ProcessInfo.processInfo.environment["VBP_MAIN_SECTION"].flatMap { Int($0) } ?? 0
        let section = Section(rawValue: initial) ?? .overview
        sidebar.select(row: section.rawValue)
        show(section)

        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in self?.refreshStatus() })
        EngineStatus.shared.onChange = { [weak self] in self?.refreshEngine() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: 呈现

    func present() {
        refresh()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func updateStatus(_ text: String) {
        overviewStatus.stringValue = text
        refreshOverview()
    }

    func refreshOverview() {
        overviewStatus.stringValue = statusProvider()
        setTranscript(latestTextProvider())
        refreshEngine()
    }

    private func setTranscript(_ text: String) {
        if lastText.string != text { lastText.string = text }
        lastTextPlaceholder.isHidden = !text.isEmpty
    }

    func refresh() {
        overviewStatus.stringValue = statusProvider()
        setTranscript(latestTextProvider())

        mode.selectItem(withTitle: settings.outputMode.title)
        autoCopy.state = settings.autoCopy ? .on : .off

        rewrite.state = settings.rewrite ? .on : .off
        rewriteEngine.selectItem(at: settings.rewriteEngine == "local" ? 1 : 0)
        rewriteEngine.item(at: 1)?.title = SemanticRewriter.localIsAvailable ? "本地 · Apple" : "本地 · Apple（不可用）"
        rewriteModel.stringValue = settings.rewriteModel

        provider.selectItem(at: ["apple", "stepfun", "whisper"].firstIndex(of: settings.asrProvider) ?? 0)
        asrModel.selectItem(withTitle: settings.asrModel)

        for (name, popup) in buttonChoices {
            popup.selectItem(withTitle: buttons.action(for: name).title)
        }

        refreshStatus()
    }

    /// 只刷新「来自外部的状态」：权限、占位符、引擎信息、模型列表。
    /// 不动用户正在编辑的输入框（窗口重新获得焦点时不能清掉草稿）。
    private func refreshStatus() {
        permissionStatus.stringValue = "语音识别：\(AppleSpeechProvider.isAuthorized ? "已授权" : "未授权")\n"
            + "辅助功能：\(AXIsProcessTrusted() ? "已授权" : "未授权")"
        recognitionKey.placeholderString = CloudKey.read(for: .recognition).isEmpty ? "StepFun API Key" : "已保存；输入新密钥可替换"
        rewriteKey.placeholderString = CloudKey.read(for: .rewrite).isEmpty ? "StepFun API Key（可选）" : "已保存；输入新密钥可替换"
        refreshEngine()
        rebuildModelList()
    }

    // MARK: 页面骨架

    private func buildPages() {
        pages[.overview] = makePage { [weak self] stack in self?.buildOverview(stack) }
        pages[.speech] = makePage { [weak self] stack in self?.buildSpeech(stack) }
        pages[.models] = makePage { [weak self] stack in self?.buildModels(stack) }
        pages[.buttons] = makePage { [weak self] stack in self?.buildButtons(stack) }
        pages[.output] = makePage { [weak self] stack in self?.buildOutput(stack) }
        pages[.rewrite] = makePage { [weak self] stack in self?.buildRewrite(stack) }
        pages[.about] = makePage { [weak self] stack in self?.buildAbout(stack) }

        for page in pages.values {
            page.translatesAutoresizingMaskIntoConstraints = false
            page.isHidden = true
            container.addSubview(page)
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                page.topAnchor.constraint(equalTo: container.topAnchor),
                page.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
    }

    /// 用滚动视图包一层竖直 stack，内容多时可滚动。
    private func makePage(_ build: (NSStackView) -> Void) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        build(stack)

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -22),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return scroll
    }

    private func show(_ section: Section) {
        currentSection = section
        for (key, page) in pages { page.isHidden = key != section }
        if section == .models { rebuildModelList() }
        if section == .overview { refreshOverview() }
    }

    // MARK: 控件工厂

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        return label
    }

    private func caption(_ text: String = "", lines: Int = 2) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = lines
        label.preferredMaxLayoutWidth = 540
        return label
    }

    private func row(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true
        control.setAccessibilityLabel(title)
        let row = NSStackView(views: [label, control])
        row.spacing = 14
        row.alignment = .centerY
        if control is NSPopUpButton { control.widthAnchor.constraint(equalToConstant: 300).isActive = true }
        return row
    }

    // MARK: 概览

    private func buildOverview(_ stack: NSStackView) {
        overviewStatus.font = .systemFont(ofSize: 20, weight: .semibold)
        overviewStatus.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(overviewStatus)
        stack.addArrangedSubview(caption("按住设备按键说话，松开后文字会按「输出」设置投递，并显示在这里。"))

        lastText.isEditable = false
        lastText.isSelectable = true
        lastText.drawsBackground = false
        lastText.font = .systemFont(ofSize: 16)
        lastText.textContainerInset = NSSize(width: 6, height: 8)
        lastTextScroll.hasVerticalScroller = true
        lastTextScroll.drawsBackground = false
        lastTextScroll.borderType = .noBorder
        lastTextScroll.documentView = lastText
        lastTextScroll.translatesAutoresizingMaskIntoConstraints = false

        // 结果面板：空的时候给出提示，避免像一块空缺。
        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.55).cgColor
        panel.layer?.cornerRadius = 8
        panel.layer?.borderWidth = 0.5
        panel.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(lastTextScroll)
        lastTextPlaceholder.font = .systemFont(ofSize: 13)
        lastTextPlaceholder.textColor = .tertiaryLabelColor
        lastTextPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(lastTextPlaceholder)
        NSLayoutConstraint.activate([
            panel.widthAnchor.constraint(equalToConstant: 560),
            panel.heightAnchor.constraint(equalToConstant: 180),
            lastTextScroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            lastTextScroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            lastTextScroll.topAnchor.constraint(equalTo: panel.topAnchor, constant: 8),
            lastTextScroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -8),
            lastTextPlaceholder.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            lastTextPlaceholder.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
        ])
        stack.addArrangedSubview(panel)

        let copyLatest = NSButton(title: "复制最近结果", target: self, action: #selector(copyLatest))
        let showLatest = NSButton(title: "显示最近结果", target: self, action: #selector(showLatest))
        let cancel = NSButton(title: "取消识别", target: self, action: #selector(cancelRecognition))
        for button in [copyLatest, showLatest, cancel] { button.bezelStyle = .rounded }
        stack.addArrangedSubview(NSStackView(views: [copyLatest, showLatest, cancel]))

        stack.addArrangedSubview(heading("本地引擎"))
        for label in [overviewBackend, overviewStats] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.maximumNumberOfLines = 2
            label.preferredMaxLayoutWidth = 540
            stack.addArrangedSubview(label)
        }

        let openLog = NSButton(title: "打开日志", target: self, action: #selector(openLog))
        openLog.bezelStyle = .rounded
        stack.addArrangedSubview(openLog)
    }

    // MARK: 语音识别

    private func buildSpeech(_ stack: NSStackView) {
        stack.addArrangedSubview(heading("识别服务"))
        provider.addItems(withTitles: ["Apple 语音识别（本机）", "StepFun 官方 API（云端）", "本地 Whisper（离线）"])
        provider.target = self; provider.action = #selector(saveRecognition)
        stack.addArrangedSubview(row("服务", provider))
        stack.addArrangedSubview(caption("Apple 本机识别延迟最低；Whisper 完全离线；StepFun 需要账户额度。切换模型请到「模型管理」。"))

        stack.addArrangedSubview(heading("StepFun 云端"))
        asrModel.addItems(withTitles: ["stepaudio-2.5-asr-stream", "step-asr-1.1-stream", "stepaudio-2.5-asr", "step-asr"])
        asrModel.target = self; asrModel.action = #selector(saveRecognition)
        stack.addArrangedSubview(row("语音模型", asrModel))
        recognitionKey.widthAnchor.constraint(equalToConstant: 300).isActive = true
        recognitionKey.placeholderString = "StepFun API Key"
        stack.addArrangedSubview(row("API Key", recognitionKey))
        stack.addArrangedSubview(caption("留空表示沿用已保存的密钥；云端整理默认复用这个 Key。"))

        let save = NSButton(title: "保存识别配置", target: self, action: #selector(saveRecognition))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        stack.addArrangedSubview(save)
        recognitionStatus.font = .systemFont(ofSize: 12)
        recognitionStatus.textColor = .secondaryLabelColor
        recognitionStatus.maximumNumberOfLines = 2
        stack.addArrangedSubview(recognitionStatus)
    }

    // MARK: 模型管理

    private func buildModels(_ stack: NSStackView) {
        stack.addArrangedSubview(heading("本地模型"))
        activeModelLabel.font = .systemFont(ofSize: 12)
        activeModelLabel.textColor = .secondaryLabelColor
        activeModelLabel.maximumNumberOfLines = 2
        stack.addArrangedSubview(activeModelLabel)

        modelStatus.font = .systemFont(ofSize: 12)
        modelStatus.textColor = .secondaryLabelColor
        modelStatus.maximumNumberOfLines = 2
        stack.addArrangedSubview(modelStatus)

        modelProgress.isIndeterminate = false
        modelProgress.minValue = 0
        modelProgress.maxValue = 100
        modelProgress.isHidden = true
        modelProgress.widthAnchor.constraint(equalToConstant: 320).isActive = true
        stack.addArrangedSubview(modelProgress)

        modelList.orientation = .vertical
        modelList.alignment = .leading
        modelList.spacing = 8
        stack.addArrangedSubview(modelList)

        let choose = NSButton(title: "导入模型文件…", target: self, action: #selector(chooseWhisperModel))
        let open = NSButton(title: "打开模型目录", target: self, action: #selector(openModelDirectory))
        let refresh = NSButton(title: "重新扫描", target: self, action: #selector(rescanModels))
        for button in [choose, open, refresh] { button.bezelStyle = .rounded }
        stack.addArrangedSubview(NSStackView(views: [choose, open, refresh]))
        stack.addArrangedSubview(caption("也可以把任意 ggml-*.bin 丢进模型目录，点「重新扫描」即可看到。下载支持断点续传。"))

        rebuildModelList()
    }

    private func rebuildModelList() {
        guard !downloadInFlight else { return }
        for view in modelList.arrangedSubviews {
            modelList.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let active = settings.whisperModel
        let models = CoreHost.modelCatalog()
        let entry = models.first { ($0["path"] as? String) == active || ($0["name"] as? String) == active }
        let activeName = entry?["name"] as? String ?? (active.isEmpty ? "未选择" : active)
        let installed = (entry?["installed"] as? Bool) ?? false
        activeModelLabel.stringValue = installed
            ? "当前使用：\(activeName)"
            : "当前使用：\(activeName)（未下载，录音时会提示缺失）"
        activeModelLabel.textColor = installed ? .secondaryLabelColor : .systemOrange

        for model in models {
            modelList.addArrangedSubview(modelCard(model, active: active))
        }
    }

    private func modelCard(_ model: [String: Any], active: String) -> NSView {
        let name = model["name"] as? String ?? "?"
        let path = model["path"] as? String ?? ""
        let installed = (model["installed"] as? Bool) ?? false
        let builtin = (model["builtin"] as? Bool) ?? true
        let size = model["sizeMb"] as? Int ?? 0
        let actual = model["actualSizeMb"] as? Int ?? size
        let quality = model["quality"] as? String ?? ""
        let isActive = builtin ? (settings.whisperModel == name) : (settings.whisperModel == path)
        let baseName = (path as NSString).lastPathComponent

        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.cornerRadius = 8
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: 560).isActive = true

        let title = NSTextField(labelWithString: builtin ? name : "\(name)（自定义）")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(labelWithString: installed
            ? "已安装 · \(actual) MB · \(quality)\(builtin ? "" : " · \(baseName)")"
            : "未下载 · \(size) MB · \(quality)")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        detail.maximumNumberOfLines = 1

        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        var actions: [NSView] = []
        if isActive {
            let badge = NSTextField(labelWithString: "使用中")
            badge.font = .systemFont(ofSize: 11, weight: .medium)
            badge.textColor = .systemGreen
            actions.append(badge)
        } else if installed {
            let use = NSButton(title: "使用", target: self, action: #selector(useModel(_:)))
            use.bezelStyle = .rounded
            use.identifier = NSUserInterfaceItemIdentifier(builtin ? name : path)
            actions.append(use)
        }

        if !installed && builtin {
            let download = NSButton(title: "下载", target: self, action: #selector(downloadModel(_:)))
            download.bezelStyle = .rounded
            download.identifier = NSUserInterfaceItemIdentifier(name)
            actions.append(download)
        }
        if installed {
            let remove = NSButton(title: "删除", target: self, action: #selector(deleteModel(_:)))
            remove.bezelStyle = .rounded
            remove.identifier = NSUserInterfaceItemIdentifier(builtin ? name : path)
            actions.append(remove)
        }

        let actionsRow = NSStackView(views: actions)
        actionsRow.spacing = 8
        actionsRow.alignment = .centerY

        let row = NSStackView(views: [text, NSView(), actionsRow])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
        ])
        return card
    }

    // MARK: 按键 / 输出 / 整理 / 关于

    private func buildButtons(_ stack: NSStackView) {
        stack.addArrangedSubview(heading("设备按键"))
        stack.addArrangedSubview(caption("每个按键的动作保存后立即生效。按住说话 / 切换录音 是录音类动作，其余是快捷键类动作。"))
        for name in ButtonSettings.buttons {
            let popup = NSPopUpButton()
            popup.addItems(withTitles: ButtonAction.allCases.map(\.title))
            popup.target = self; popup.action = #selector(changeButtons)
            buttonChoices[name] = popup
            stack.addArrangedSubview(row(name.uppercased(), popup))
        }
    }

    private func buildOutput(_ stack: NSStackView) {
        stack.addArrangedSubview(heading("识别输出"))
        mode.addItems(withTitles: OutputMode.allCases.map(\.title))
        mode.target = self; mode.action = #selector(changeOutput)
        stack.addArrangedSubview(row("输出方式", mode))
        autoCopy.target = self; autoCopy.action = #selector(changeOutput)
        stack.addArrangedSubview(row("完成后自动复制", autoCopy))
        stack.addArrangedSubview(caption("实时输入会边识别边写入当前输入框；完成后粘贴模拟 Command-V；仅悬浮窗只显示结果。"))
    }

    private func buildRewrite(_ stack: NSStackView) {
        stack.addArrangedSubview(heading("轻度语义整理"))
        rewrite.target = self; rewrite.action = #selector(saveRewrite)
        stack.addArrangedSubview(row("启用整理", rewrite))
        stack.addArrangedSubview(caption("纠错、补标点、去口头重复，保持原意。云端会复用识别 Key。"))
        rewriteEngine.addItems(withTitles: ["云端 · StepFun", "本地 · Apple"])
        rewriteEngine.target = self; rewriteEngine.action = #selector(saveRewrite)
        stack.addArrangedSubview(row("整理引擎", rewriteEngine))
        rewriteModel.widthAnchor.constraint(equalToConstant: 300).isActive = true
        stack.addArrangedSubview(row("整理模型", rewriteModel))
        rewriteKey.widthAnchor.constraint(equalToConstant: 300).isActive = true
        rewriteKey.placeholderString = "可选，单独用于整理的 Key"
        stack.addArrangedSubview(row("API Key", rewriteKey))

        let save = NSButton(title: "保存整理配置", target: self, action: #selector(saveRewrite))
        let test = NSButton(title: "测试云端整理", target: self, action: #selector(testCloud))
        save.bezelStyle = .rounded; test.bezelStyle = .rounded
        stack.addArrangedSubview(NSStackView(views: [save, test]))
        rewriteStatus.font = .systemFont(ofSize: 12)
        rewriteStatus.textColor = .secondaryLabelColor
        rewriteStatus.maximumNumberOfLines = 2
        stack.addArrangedSubview(rewriteStatus)
    }

    private func buildAbout(_ stack: NSStackView) {
        stack.addArrangedSubview(heading("关于"))
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        stack.addArrangedSubview(caption("VibeBoard Plus \(version) · 内核 v\(CoreHost.version())"))
        stack.addArrangedSubview(caption("日志：\(VLog.path)"))

        permissionStatus.font = .systemFont(ofSize: 12)
        permissionStatus.textColor = .secondaryLabelColor
        permissionStatus.maximumNumberOfLines = 3
        stack.addArrangedSubview(permissionStatus)

        let speech = NSButton(title: "授权语音识别", target: self, action: #selector(authorizeSpeech))
        let access = NSButton(title: "授权辅助功能", target: self, action: #selector(authorizeAccess))
        speech.bezelStyle = .rounded; access.bezelStyle = .rounded
        stack.addArrangedSubview(NSStackView(views: [speech, access]))

        let openLog = NSButton(title: "打开日志", target: self, action: #selector(openLog))
        openLog.bezelStyle = .rounded
        stack.addArrangedSubview(openLog)
    }

    // MARK: 引擎状态

    private func refreshEngine() {
        let backend = EngineStatus.shared.backend
        let summary = EngineStatus.shared.lastStats?.summary ?? "尚无本地识别记录"
        if let backend {
            let text = "\(backend.active)（已编译 \(backend.compiled.joined(separator: " / "))）"
            overviewBackend.stringValue = "本地引擎：\(text)"
        } else {
            overviewBackend.stringValue = "本地引擎：此构建未包含 Whisper"
        }
        overviewStats.stringValue = summary
    }

    // MARK: 动作：配置

    @objc private func changeOutput() {
        settings.outputMode = OutputMode.allCases[mode.indexOfSelectedItem]
        settings.autoCopy = autoCopy.state == .on
        NotificationCenter.default.post(name: .vibeboardConfigurationChanged, object: nil)
    }

    @objc private func changeButtons() {
        buttons.save(buttonChoices.mapValues { ButtonAction.allCases[$0.indexOfSelectedItem] })
        NotificationCenter.default.post(name: .vibeboardConfigurationChanged, object: nil)
    }

    private func saveKey(_ field: NSSecureTextField, purpose: CloudKey.Purpose, status: NSTextField) -> Bool {
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            guard CloudKey.save(key, for: purpose) else {
                status.stringValue = "密钥保存失败，请检查钥匙串访问权限"
                return false
            }
            field.stringValue = ""
        }
        return true
    }

    @objc private func saveRecognition() {
        guard saveKey(recognitionKey, purpose: .recognition, status: recognitionStatus) else { return }
        settings.asrProvider = ["apple", "stepfun", "whisper"][provider.indexOfSelectedItem]
        settings.asrModel = asrModel.titleOfSelectedItem ?? "stepaudio-2.5-asr-stream"
        recognitionStatus.stringValue = "识别配置已保存，下次录音生效"
        NotificationCenter.default.post(name: .vibeboardConfigurationChanged, object: nil)
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
        NotificationCenter.default.post(name: .vibeboardConfigurationChanged, object: nil)
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

    // MARK: 动作：模型

    @objc private func useModel(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, !value.isEmpty else { return }
        settings.whisperModel = value
        NotificationCenter.default.post(name: .vibeboardConfigurationChanged, object: nil)
        modelStatus.stringValue = "已切换到 \(value)"
        rebuildModelList()
    }

    @objc private func downloadModel(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue, !name.isEmpty, !downloadInFlight else { return }
        downloadInFlight = true
        sender.isEnabled = false
        modelProgress.isHidden = false
        modelProgress.doubleValue = 0
        modelStatus.stringValue = "正在下载 \(name)…"

        CoreHost.downloadModel(name, progress: { [weak self] fraction, received in
            guard let self else { return }
            self.modelProgress.doubleValue = (fraction ?? 0) * 100
            let mb = Double(received) / 1024 / 1024
            self.modelStatus.stringValue = fraction == nil
                ? String(format: "正在下载 %@… %.0f MB", name, mb)
                : String(format: "正在下载 %@… %.0f%%", name, (fraction ?? 0) * 100)
        }, completion: { [weak self] error in
            guard let self else { return }
            self.downloadInFlight = false
            self.modelProgress.isHidden = true
            self.modelStatus.stringValue = error ?? "已下载 \(name)"
            self.rebuildModelList()
        })
    }

    @objc private func deleteModel(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, !value.isEmpty else { return }
        let label = (value as NSString).lastPathComponent
        let alert = NSAlert()
        alert.messageText = "删除模型 \(label)？"
        alert.informativeText = "文件会从磁盘删除，需要时可以重新下载。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let catalog = CoreHost.modelCatalog()
        let target = catalog.first { ($0["name"] as? String) == value }?["path"] as? String ?? value
        if let error = CoreHost.removeModel(target) {
            modelStatus.stringValue = "删除失败：\(error)"
            return
        }
        if settings.whisperModel == value || settings.whisperModel == label {
            settings.whisperModel = ""
            NotificationCenter.default.post(name: .vibeboardConfigurationChanged, object: nil)
        }
        modelStatus.stringValue = "已删除 \(label)"
        rebuildModelList()
    }

    @objc private func rescanModels() {
        modelStatus.stringValue = "已重新扫描"
        rebuildModelList()
    }

    @objc private func chooseWhisperModel() {
        let panel = NSOpenPanel()
        panel.title = "导入 Whisper 模型文件"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let destination = URL(fileURLWithPath: CoreHost.modelDirectory()).appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(atPath: CoreHost.modelDirectory(), withIntermediateDirectories: true)
            if destination.path != url.path {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: url, to: destination)
            }
            settings.whisperModel = destination.path
            modelStatus.stringValue = "已导入 \(url.lastPathComponent)"
            NotificationCenter.default.post(name: .vibeboardConfigurationChanged, object: nil)
            rebuildModelList()
        } catch {
            modelStatus.stringValue = "导入失败：\(error.localizedDescription)"
        }
    }

    @objc private func openModelDirectory() {
        let path = CoreHost.modelDirectory()
        guard !path.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // MARK: 动作：概览 / 关于

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: VLog.path))
    }

    @objc private func copyLatest() {
        let text = latestTextProvider()
        guard !text.isEmpty else { overviewStatus.stringValue = "暂无识别结果"; return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        overviewStatus.stringValue = "已复制识别结果"
    }

    @objc private func showLatest() {
        let text = latestTextProvider()
        setTranscript(text)
        overviewStatus.stringValue = text.isEmpty ? "暂无识别结果" : "最近识别结果"
    }

    @objc private func cancelRecognition() {
        onCancel?()
        overviewStatus.stringValue = "已取消识别"
    }

    @objc private func authorizeSpeech() {
        AppleSpeechProvider.requestAuthorization { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    @objc private func authorizeAccess() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        refresh()
    }

    // MARK: 供测试使用

    var sectionTitles: [String] { Section.allCases.map(\.title) }
    var pageViews: [NSView] { Section.allCases.compactMap { pages[$0] } }
    func selectSection(_ index: Int) {
        guard let section = Section(rawValue: index) else { return }
        sidebar.select(row: index)
        show(section)
    }
}
