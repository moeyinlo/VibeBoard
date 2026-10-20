import AVFoundation
import Opus

/// 音频链路自测：`say` 合成中文语音 → 16kHz float32 → Opus 编码（模拟设备上行帧）→
/// DeviceAudioDecoder 解码 → Apple 本机识别（SFSpeechRecognizer）。
/// 不依赖实体按键即可验证「设备 Opus 帧 → 本机识别」整条原生音频流。
///
/// 触发方式：`touch /tmp/vbp_selftest_go`（App 每 2s 轮询，触发后自删）。
/// 识别结果经 pipeline.onText 以 `[text final] …` 打进日志。
enum AudioSelfTest {
    static let triggerPath = "/tmp/vbp_selftest_go"
    static let audioPath = "/tmp/vbp_selftest.caf"

    /// 20ms 帧 @16kHz（与设备上行一致的典型帧长）
    private static let samplesPerFrame = 320

    static func startPolling(provider: @escaping () -> AppleSpeechProvider?) {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            guard FileManager.default.fileExists(atPath: triggerPath) else { return }
            try? FileManager.default.removeItem(atPath: triggerPath)
            guard AppleSpeechProvider.isAuthorized else {
                vlog("[selftest] speech not authorized — 请先在授权弹窗点允许")
                return
            }
            guard let apple = provider() else {
                vlog("[selftest] apple provider not ready（设备尚未完成配对）")
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                run(apple: apple)
            }
        }
    }

    private static func run(apple: AppleSpeechProvider) {
        vlog("[selftest] === start ===")
        do {
            let frames = try synthOpusFrames()
            let total = frames.reduce(0) { $0 + $1.count }
            vlog("[selftest] encoded \(frames.count) opus frames (\(total)B, ~\(frames.count * 20)ms audio)")
            apple.startSession()
            for (i, frame) in frames.enumerated() {
                apple.sendAudio(frame)
                if i % 10 == 0 { Thread.sleep(forTimeInterval: 0.02) } // 轻微节流，让 partial 结果流式产出
            }
            vlog("[selftest] all frames fed — waiting final transcript…")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                apple.finishSession()
                vlog("[selftest] === finished，识别文本见上方 [text final] 行 ===")
            }
        } catch {
            vlog("[selftest] FAILED: \(error)")
        }
    }

    /// say 合成 → 读 16k float32 → 切 20ms 帧 → Opus 编码
    private static func synthOpusFrames() throws -> [Data] {
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", audioPath, "--data-format=LEF32@16000",
                         "你好，今天天气怎么样？这里是苹果本机语音识别链路测试。"]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else {
            throw NSError(domain: "selftest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "say rc=\(say.terminationStatus)"])
        }
        defer { try? FileManager.default.removeItem(atPath: audioPath) }

        let file = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath))
        let fmt = file.processingFormat
        vlog("[selftest] source: \(Int(fmt.sampleRate))Hz ch=\(fmt.channelCount) \(fmt.commonFormat == .pcmFormatFloat32 ? "f32" : String(describing: fmt.commonFormat))")
        guard fmt.sampleRate == 16000, fmt.channelCount == 1, fmt.commonFormat == .pcmFormatFloat32 else {
            throw NSError(domain: "selftest", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "unexpected audio format"])
        }
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "selftest", code: 4)
        }
        try file.read(into: buf)
        guard let floats = buf.floatChannelData?[0] else {
            throw NSError(domain: "selftest", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "no float channel data"])
        }

        let encoder = try Opus.Encoder(format: fmt)
        var frames = [Data]()
        var offset = 0
        while offset + samplesPerFrame <= Int(buf.frameLength) {
            guard let chunk = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samplesPerFrame)) else {
                throw NSError(domain: "selftest", code: 4)
            }
            chunk.frameLength = AVAudioFrameCount(samplesPerFrame)
            memcpy(chunk.floatChannelData![0], floats + offset, samplesPerFrame * MemoryLayout<Float>.size)
            var data = Data(count: 2000) // 预留最大包长，encode 内部会截断为实际字节数
            _ = try encoder.encode(chunk, to: &data)
            frames.append(data)
            offset += samplesPerFrame
        }
        return frames
    }
}
