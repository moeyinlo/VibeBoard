import AVFoundation
import Opus
import XCTest
@testable import VibeBoardPlus

final class DeviceAudioDecoderTests: XCTestCase {
    func testDeviceOpusPacketsDecodeToSixteenKilohertzPCM() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320))
        input.frameLength = 320
        let samples = try XCTUnwrap(input.floatChannelData?[0])
        for index in 0..<320 {
            samples[index] = sin(Float(index) * 0.1) * 0.3
        }
        let encoder = try Opus.Encoder(format: format)
        var packet = Data(count: 2000)
        _ = try encoder.encode(input, to: &packet)

        let decoder = DeviceAudioDecoder()
        let decoded = try XCTUnwrap(decoder.decode(packet).first)
        XCTAssertEqual(decoded.frameLength, 320)
        XCTAssertEqual(decoded.format.sampleRate, 16000)
        XCTAssertEqual(decoded.format.channelCount, 1)
        XCTAssertTrue(decoder.decode(Data()).isEmpty)
    }
}
