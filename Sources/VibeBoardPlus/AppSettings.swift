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
    /// Local Whisper model name; see `models::MODELS` in the core for the catalogue.
    var whisperModel: String {
        get { defaults.string(forKey: "whisperModel") ?? "large-v3-turbo-q5_0" }
        set { defaults.set(newValue, forKey: "whisperModel") }
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
        get {
            // Cloud cleanup is on by default; the user can turn it off in the main window.
            guard defaults.object(forKey: "semanticRewrite") != nil else { return true }
            return defaults.bool(forKey: "semanticRewrite")
        }
        set { defaults.set(newValue, forKey: "semanticRewrite") }
    }
}

extension Notification.Name {
    /// Posted after the main window writes anything the core needs to know about.
    static let vibeboardConfigurationChanged = Notification.Name("vb.config.changed")
}
