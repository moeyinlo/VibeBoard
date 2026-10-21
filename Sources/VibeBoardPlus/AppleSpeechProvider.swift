import AVFoundation
import Speech

/// Apple's on-device recogniser, fed by the shared core.
///
/// The Rust core owns the device link and decodes Opus, so this type only receives 16 kHz
/// mono PCM16 and returns transcripts through `onText`. Results are handed back to the core
/// with `vb_core_external_text`, which keeps device screen state and output routing in one
/// place.
final class AppleSpeechProvider {
    enum State {
        case idle
        case recording
        case finishing
    }

    /// Called with (text, isFinal). Invoked on an arbitrary queue.
    var onText: ((String, Bool) -> Void)?

    private static let deviceSampleRate: Double = 16_000

    private let locale: Locale
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var format: AVAudioFormat?
    private(set) var state: State = .idle
    private var lastText = ""
    private var generation = UUID()

    init(localeIdentifier: String = "zh-CN") {
        locale = Locale(identifier: localeIdentifier)
    }

    static var isAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    static func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            completion(status == .authorized)
        }
    }

    /// True when on-device recognition can run (authorized + recogniser available).
    var isAvailable: Bool {
        Self.isAuthorized && SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true
    }

    @discardableResult
    func start() -> Bool {
        guard isAvailable else {
            vlog("[apple] 本机识别不可用（授权或语言包缺失）")
            return false
        }
        cancel()
        let recognizer = SFSpeechRecognizer(locale: locale)
        self.recognizer = recognizer
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: Self.deviceSampleRate,
                                         channels: 1,
                                         interleaved: true) else { return false }
        self.format = format

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        if #available(macOS 13.0, *) { request.addsPunctuation = true }
        self.request = request
        lastText = ""
        let current = UUID()
        generation = current
        state = .recording

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self, self.generation == current else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                if !text.isEmpty {
                    self.lastText = text
                    self.onText?(text, false)
                }
                if result.isFinal {
                    self.state = .idle
                    self.onText?(text.isEmpty ? self.lastText : text, true)
                }
            } else if error != nil {
                // A recognition error during dictation keeps whatever was already produced;
                // the core decides whether to show partial text or an empty result.
                self.state = .idle
                self.onText?(self.lastText, true)
            }
        }
        vlog("[apple] 本机识别已启动")
        return true
    }

    /// Appends decoded device audio (16 kHz mono PCM16, little endian).
    func append(pcm: Data) {
        guard state == .recording, let request, let format else { return }
        let frames = pcm.count / 2
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            if let destination = buffer.int16ChannelData?[0], let source = raw.bindMemory(to: Int16.self).baseAddress {
                destination.update(from: source, count: frames)
            }
        }
        request.append(buffer)
    }

    /// Ends the audio stream; the recognition task delivers the final transcript.
    func finish() {
        guard state == .recording else { return }
        state = .finishing
        request?.endAudio()
        vlog("[apple] 音频结束，等待最终结果")
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        recognizer = nil
        state = .idle
        lastText = ""
    }

    /// Session teardown after a final transcript was delivered.
    func reset() {
        task = nil
        request = nil
        recognizer = nil
        format = nil
        state = .idle
        lastText = ""
    }
}
