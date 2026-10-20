import Foundation
import AVFoundation
import Speech
import Opus

/// 苹果系统语音识别（Speech 框架 / SFSpeechRecognizer）——设备麦克风直通模式。
///
/// 音频源是 VibeBoard 硬件麦克风经 USB 上行的音频帧，**不使用电脑麦克风**
/// （需求确认：电脑麦克风不可用，键盘端麦克风是唯一输入源）。
/// - USB 帧为 16kHz/单声道/16-bit PCM 时直接注入；为 Opus 时经 DeviceAudioDecoder 解码后注入
/// - 本机识别（requiresOnDeviceRecognition）：无网络往返，延迟最低
final class AppleSpeechProvider: NSObject, ASRProvider, SFSpeechRecognizerDelegate {
    let name = "apple-speech"
    let latencyClass: LatencyClass = .local

    private let pipeline: ASRPipeline
    private let locale: Locale
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = UUID()

    /// 设备音频解码器（Opus→PCM；PCM 帧透传）
    private let decoder = DeviceAudioDecoder()

    /// 设备音频参数（PROTOCOL.md §4-5，真机抓包后按实际值修正）
    static let deviceSampleRate: Double = 16000
    static let deviceChannels: AVAudioChannelCount = 1

    static var isAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    static func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            completion(status == .authorized)
        }
    }

    init(pipeline: ASRPipeline, localeIdentifier: String = "zh-CN") {
        self.pipeline = pipeline
        self.locale = Locale(identifier: localeIdentifier)
        super.init()
        recognizer = SFSpeechRecognizer(locale: locale)
        recognizer?.delegate = self
    }

    var isAvailable: Bool {
        guard let recognizer else { return false }
        return recognizer.isAvailable && Self.isAuthorized
    }

    func startSession() {
        audioQueue.sync { startOnQueue() }
    }

    private func startOnQueue() {
        guard isAvailable else { return }
        task?.cancel()
        generation = UUID()
        let currentGeneration = generation

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        decoder.reset()

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            self.audioQueue.async {
                guard self.generation == currentGeneration else { return }
                if let result {
                    self.pipeline.broadcastText(result.bestTranscription.formattedString, isFinal: result.isFinal)
                }
                if error != nil || (result?.isFinal ?? false) {
                    if error != nil, result?.isFinal != true {
                        self.pipeline.broadcastText("", isFinal: true)
                    }
                    self.request = nil
                    self.task = nil
                }
            }
        }
    }

    /// USB 设备音频帧入口（Coordinator 从 USBDeviceManager 转发过来）。
    /// 帧格式：PCM(16k/mono/s16le) 直接注入；Opus 帧解码后注入。
    private let audioQueue = DispatchQueue(label: "vibeboardplus.speech.audio")

    func sendAudio(_ data: Data) {
        audioQueue.async { [weak self] in
            guard let self, let request = self.request else { return }
            for buffer in self.decoder.decode(data) {
                request.append(buffer)
            }
        }
    }

    func finishSession() {
        audioQueue.async { [self] in
            request?.endAudio()
            request = nil
        }
    }

    func stop() {
        audioQueue.async { [self] in
            generation = UUID()
            task?.cancel()
            task = nil
            request = nil
        }
    }

    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        // 不可用时上层 pipeline 会自动回退到远程 provider
    }
}

/// 设备音频帧解码：PCM 透传 / Opus→PCM。
/// USB 帧封装格式（JSON 还是 TLV）待真机抓包确认后在此收敛。
final class DeviceAudioDecoder {
    private var opusDecoder: OpusDecoder?

    func reset() {
        opusDecoder?.reset()
    }

    func decode(_ frame: Data) -> [AVAudioPCMBuffer] {
        if isRawPCM(frame) {
            return [makePCMBuffer(from: frame)].compactMap { $0 }
        }
        // Opus 帧：解码为 PCM buffer
        if opusDecoder == nil {
            opusDecoder = OpusDecoder(sampleRate: AppleSpeechProvider.deviceSampleRate,
                                      channels: AppleSpeechProvider.deviceChannels)
        }
        return [opusDecoder?.decode(frame)].compactMap { $0 }
    }

    /// 简易启发：设备固件若上行裸 PCM，帧长与 16k/mono/s16 恰合（20ms=640B）。
    /// 抓包后如有帧头魔法，在此增加识别分支。
    private func isRawPCM(_ frame: Data) -> Bool {
        frame.count % 2 == 0 && (frame.count == 640 || frame.count == 320 || frame.count == 1280)
    }

    private func makePCMBuffer(from pcm: Data) -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                   sampleRate: AppleSpeechProvider.deviceSampleRate,
                                   channels: AppleSpeechProvider.deviceChannels,
                                   interleaved: true)!
        let frameCount = AVAudioFrameCount(pcm.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            buffer.int16ChannelData![0].update(from: raw.bindMemory(to: Int16.self).baseAddress!, count: Int(frameCount))
        }
        return buffer
    }
}

/// Opus 解码（alta/swift-opus，libopus）：设备音频帧 → PCM buffer → 苹果本机识别
final class OpusDecoder {
    private let decoder: Opus.Decoder?

    init(sampleRate: Double, channels: AVAudioChannelCount) {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)
        decoder = format.flatMap { try? Opus.Decoder(format: $0) }
    }

    func reset() {
        try? decoder?.reset()
    }

    func decode(_ frame: Data) -> AVAudioPCMBuffer? {
        try? decoder?.decode(frame)
    }
}
