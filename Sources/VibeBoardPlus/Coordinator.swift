import AppKit
import Foundation

/// Thin AppKit adapter over the shared Rust core.
///
/// Everything device/protocol/auth/ASR related now lives in `vibeboard-core`; this class only
/// forwards core callbacks into the menu bar controller and pushes configuration changes back.
final class VibeBoardCoordinator {
    var onFinalText: ((String) -> Void)?
    var onPartialText: ((String) -> Void)?
    var onSessionStart: (() -> Void)?
    var onButtonAction: ((ButtonAction) -> Void)?
    var onRecognitionCancelled: (() -> Void)?
    var onStatus: ((String) -> Void)?

    let buttonSettings = ButtonSettings()
    private let host: CoreHost

    init() {
        host = CoreHost(buttonSettings: buttonSettings)
        host.onStatus = { [weak self] text in
            vlog("[status] \(text)")
            self?.onStatus?(text)
        }
        host.onPartialText = { [weak self] text in
            vlog("[text] \(text)")
            self?.onPartialText?(text)
        }
        host.onFinalText = { [weak self] text in
            vlog("[text final] \(text)")
            self?.onFinalText?(text)
        }
        host.onSessionStart = { [weak self] in self?.onSessionStart?() }
        host.onCancelled = { [weak self] in self?.onRecognitionCancelled?() }
        host.onError = { text in vlog("[core] \(text)") }
        host.onAction = { [weak self] action in self?.onButtonAction?(action) }
    }

    func start() {
        host.start()
    }

    func stop() {
        host.stop()
    }

    /// Re-reads settings and hands them to the core (provider, model, keys, button map).
    func refreshConfiguration() {
        host.updateConfiguration()
    }

    func cancelRecognition() {
        host.cancel()
    }

    var latestResult: String { host.lastText() }
    var speechProvider: AppleSpeechProvider { host.speechProvider }
}
