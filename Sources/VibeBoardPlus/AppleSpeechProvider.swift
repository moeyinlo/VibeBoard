import Foundation
import AVFoundation
import Speech
import Opus

/// 苹果系统语音识别（Speech 框架 / SFSpeechRecognizer）——设备麦克风直通模式。
///
/// 音频源是 VibeBoard 硬件麦克风经 USB 上行的音频帧，**不使用电脑麦克风**
/// （需求确认：电脑麦克风不可用，键盘端麦克风是唯一输入源）。
/// - USB 帧中的 Opus 载荷经 DeviceAudioDecoder 解码后注入
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
    private var audioFrames = 0
    private var audioSamples = 0

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
        guard isAvailable else {
            diag("本机识别启动失败：Speech 不可用或未授权")
            pipeline.broadcastText("", isFinal: true)
            return
        }
        task?.cancel()
        generation = UUID()
        let currentGeneration = generation

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        diag("本机识别启动：设备端模式=\(request.requiresOnDeviceRecognition)")
        self.request = request
        decoder.reset()
        audioFrames = 0
        audioSamples = 0

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            self.audioQueue.async {
                guard self.generation == currentGeneration else { return }
                if let result {
                    self.pipeline.broadcastText(result.bestTranscription.formattedString, isFinal: result.isFinal)
                }
                if error != nil || (result?.isFinal ?? false) {
                    if let error, result?.isFinal != true {
                        diag("本机识别错误：\(error.localizedDescription)")
                        self.pipeline.broadcastText("", isFinal: true)
                    }
                    self.request = nil
                    self.task = nil
                }
            }
        }
    }

    /// USB 设备音频帧入口（Coordinator 从 USBDeviceManager 转发过来）。
    /// 帧格式：设备 Opus 载荷解码后注入。
    private let audioQueue = DispatchQueue(label: "vibeboardplus.speech.audio")

    func sendAudio(_ data: Data) {
        audioQueue.async { [weak self] in
            guard let self, let request = self.request else { return }
            let buffers = self.decoder.decode(data)
            self.audioFrames += 1
            for buffer in buffers {
                self.audioSamples += Int(buffer.frameLength)
                request.append(buffer)
            }
            if self.audioFrames == 1 || self.audioFrames % 50 == 0 {
                diag("本机音频解码：\(self.audioFrames) 帧，\(self.audioSamples) 采样")
            }
        }
    }

    func finishSession() {
        audioQueue.async { [self] in
            diag("本机音频输入结束：\(audioFrames) 帧，\(audioSamples) 采样")
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
        if !available { diag("本机识别服务已不可用") }
    }
}

/// 设备音频帧的 Opus 载荷解码为 16 kHz 单声道 PCM。
final class DeviceAudioDecoder {
    private var opusDecoder: OpusDecoder?

    func reset() {
        opusDecoder?.reset()
    }

    func decode(_ frame: Data) -> [AVAudioPCMBuffer] {
        guard !frame.isEmpty else { return [] }
        if opusDecoder == nil {
            opusDecoder = OpusDecoder(sampleRate: AppleSpeechProvider.deviceSampleRate,
                                      channels: AppleSpeechProvider.deviceChannels)
        }
        return [opusDecoder?.decode(frame)].compactMap { $0 }
    }
}

/// Opus 解码（alta/swift-opus，libopus）：设备音频帧 → PCM buffer → 苹果本机识别
final class OpusDecoder {
    private let decoder: Opus.Decoder?
    private var failures = 0

    init(sampleRate: Double, channels: AVAudioChannelCount) {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)
        decoder = format.flatMap { try? Opus.Decoder(format: $0) }
        if decoder == nil { diag("设备音频解码器初始化失败") }
    }

    func reset() {
        failures = 0
        do { try decoder?.reset() }
        catch { diag("设备 Opus 解码器重置失败：\(error.localizedDescription)") }
    }

    func decode(_ frame: Data) -> AVAudioPCMBuffer? {
        guard let decoder else { return nil }
        do {
            return try decoder.decode(frame)
        } catch {
            failures += 1
            if failures == 1 || failures % 50 == 0 {
                diag("设备 Opus 解码失败：\(failures) 帧，\(error.localizedDescription)")
            }
            return nil
        }
    }
}
