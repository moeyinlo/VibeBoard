import AppKit
import ApplicationServices

final class MenuBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let status = NSMenuItem(title: "等待设备", action: nil, keyEquivalent: "")
    private var latestText = ""
    private let output = RecognitionOutput()
    private let keyboard = KeyboardActionSender()
    private var mainWindow: MainWindowController?
    private var diagnosticWindow: DiagnosticWindow?
    private let settings = AppSettings()
    var buttonSettings: ButtonSettings?
    private var rewriteTask: Task<Void, Never>?
    private var rewriteTimeout: DispatchWorkItem?
    private var generation = UUID()

    override init() {
        super.init()
        keyboard.onStatus = { [weak self] text in
            self?.status.title = text
            if !text.hasPrefix("已发送") { self?.output.showLatest(text) }
        }
        item.button?.title = "VB+"
        item.button?.toolTip = "VibeBoard Plus"
        let menu = NSMenu()
        menu.addItem(status)
        menu.addItem(.separator())
        add("打开主窗口…", action: #selector(showMainWindow), to: menu)
        add("诊断日志…", action: #selector(showDiagnostics), to: menu)
        add("显示最近识别结果", action: #selector(showLatest), to: menu)
        add("复制最近识别结果", action: #selector(copyText), to: menu)
        menu.addItem(.separator())
        add("退出 VibeBoard Plus", action: #selector(quit), to: menu)
        item.menu = menu
    }

    private func add(_ title: String, action: Selector, to menu: NSMenu) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        menu.addItem(entry)
    }

    func updateStatus(_ text: String) {
        status.title = text
        mainWindow?.updateStatus(text)
        output.status(text)
        if text == "设备已断开" {
            generation = UUID()
            rewriteTask?.cancel()
            rewriteTimeout?.cancel()
            output.cancel()
        }
    }

    func beginRecognition() {
        mainWindow?.refreshOverview()
        generation = UUID()
        rewriteTask?.cancel()
        rewriteTimeout?.cancel()
        output.begin(mode: settings.outputMode, autoCopy: settings.autoCopy)
    }
    func receivePartial(_ text: String) {
        output.receive(text, final: false)
        mainWindow?.refreshOverview()
    }

    func receive(_ text: String) {
        latestText = text
        mainWindow?.refreshOverview()
        status.title = "识别完成"
        guard settings.rewrite, !text.isEmpty, SemanticRewriter.isAvailable else {
            output.receive(text, final: true)
            return
        }
        output.receive(text, final: false)
        output.status("正在整理")
        status.title = "正在整理"
        let current = generation
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == current else { return }
            self.generation = UUID()
            self.rewriteTask?.cancel()
            self.output.receive(text, final: true)
            self.status.title = "整理超时，已保留原文"
            self.output.status(self.status.title)
        }
        rewriteTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + (settings.rewriteEngine == "local" ? 15 : 30), execute: timeout)
        rewriteTask = Task { @MainActor [weak self] in
            do {
                let cleaned = try await SemanticRewriter.rewrite(text)
                guard let self, self.generation == current else { return }
                self.rewriteTimeout?.cancel()
                self.latestText = cleaned
                vlog("[rewrite] \(cleaned)")
                self.output.receive(cleaned, final: true)
                self.status.title = "整理完成"
                self.output.status("整理完成")
            } catch {
                guard let self, self.generation == current else { return }
                self.rewriteTimeout?.cancel()
                vlog("[rewrite] 失败，保留原文：\(error)")
                self.output.receive(text, final: true)
                self.status.title = (error as? SemanticRewriteError)?.errorDescription ?? "整理失败，已保留原文"
                self.output.status(self.status.title)
            }
        }
    }

    @objc private func showLatest() { output.showLatest(latestText) }

    @objc private func showMainWindow() {
        guard let buttonSettings else { return }
        if mainWindow == nil {
            let controller = MainWindowController(settings: settings, buttons: buttonSettings)
            controller.statusProvider = { [weak self] in self?.status.title ?? "等待设备" }
            controller.latestTextProvider = { [weak self] in self?.latestText ?? "" }
            controller.onCancel = { [weak self] in self?.cancelRecognition() }
            mainWindow = controller
        }
        mainWindow?.present()
    }

    @objc private func showDiagnostics() {
        if diagnosticWindow == nil { diagnosticWindow = DiagnosticWindow() }
        diagnosticWindow?.present()
    }

    /// 启动时直接展示主窗口（截图 / 调试用）。
    func openMainWindowForDebugging() {
        showMainWindow()
    }

    func cancelRecognition() {
        generation = UUID()
        rewriteTask?.cancel()
        rewriteTimeout?.cancel()
        output.cancel()
    }

    func performButtonAction(_ action: ButtonAction) {
        switch action {
        case .copyResult: copyText(); status.title = latestText.isEmpty ? "暂无识别结果" : "已复制识别结果"
        case .showResult: showLatest()
        case .paste, .undo, .enter, .escape:
            keyboard.send(action)
        default: break
        }
    }

    @objc private func copyText() {
        guard !latestText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(latestText, forType: .string)
    }

    @objc private func authorizeInput() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    @objc private func authorizeSpeech() {
        AppleSpeechProvider.requestAuthorization { granted in
            DispatchQueue.main.async { self.status.title = granted ? "语音识别已授权" : "语音识别未授权" }
        }
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
