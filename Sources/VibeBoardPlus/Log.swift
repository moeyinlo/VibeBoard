import Foundation
import AppKit

/// 全局日志：stderr + 文件双写。
/// 经 LaunchServices（open *.app）启动时 stderr 进黑洞，文件是唯一可观测渠道。
enum VLog {
    static let path = "/tmp/vibeboardplus.log"
    private static let queue = DispatchQueue(label: "vibeboardplus.log")
    private static var handle = makeHandle()

    private static let formatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    /// 每次启动截断重开，避免跨运行混淆
    static func reset() {
        queue.sync { handle = makeHandle() }
    }

    static func write(_ msg: String) {
        let line = "[\(formatter.string(from: Date()))] \(msg)\n"
        FileHandle.standardError.write(Data(line.utf8))
        queue.async {
            handle.write(Data(line.utf8))
        }
    }

    private static func makeHandle() -> FileHandle {
        FileManager.default.createFile(atPath: path, contents: nil)
        return (try? FileHandle(forWritingTo: URL(fileURLWithPath: path))) ?? FileHandle.standardError
    }
}

func vlog(_ msg: String) {
    VLog.write(msg)
}

enum DiagnosticLog {
    static let didChange = Notification.Name("vibeboardplus.diagnostics.changed")
    private(set) static var entries: [String] = []

    static func add(_ message: String) {
        vlog("[diagnostic] \(message)")
        DispatchQueue.main.async {
            let line = "[\(Date().formatted(date: .omitted, time: .standard))] \(message)"
            entries.append(line)
            if entries.count > 300 { entries.removeFirst(entries.count - 300) }
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static func clear() {
        entries.removeAll()
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

func diag(_ message: String) { DiagnosticLog.add(message) }

final class DiagnosticWindow: NSWindowController {
    private let text = NSTextView()
    private var observer: NSObjectProtocol?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 440),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "诊断日志"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let content = NSView()
        window.contentView = content
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        text.frame = scroll.contentView.bounds
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 8, height: 8)
        scroll.documentView = text
        content.addSubview(scroll)

        let copy = NSButton(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "复制日志")!,
                            target: self, action: #selector(copyLog))
        copy.toolTip = "复制日志"
        let clear = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "清空日志")!,
                             target: self, action: #selector(clearLog))
        clear.toolTip = "清空日志"
        let controls = NSStackView(views: [copy, clear])
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            controls.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
        observer = NotificationCenter.default.addObserver(forName: DiagnosticLog.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        refresh()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func present() {
        refresh()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func refresh() {
        text.string = DiagnosticLog.entries.joined(separator: "\n")
        text.scrollRangeToVisible(NSRange(location: text.string.utf16.count, length: 0))
    }

    @objc private func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text.string, forType: .string)
    }

    @objc private func clearLog() { DiagnosticLog.clear() }
}
