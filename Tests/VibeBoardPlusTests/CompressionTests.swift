import XCTest
import zlib
@testable import VibeBoardPlus

final class CompressionTests: XCTestCase {
    func testGzipRoundTrip() throws {
        for input in [Data(), Data("你好 VibeBoard".utf8), Data((0..<100000).map { UInt8(truncatingIfNeeded: $0 * 37) })] {
            let compressed = try input.gzipped()
            var stream = z_stream()
            XCTAssertEqual(inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)), Z_OK)
            defer { inflateEnd(&stream) }
            var output = [UInt8](repeating: 0, count: input.count + 1)
            let result = compressed.withUnsafeBytes { bytes in
                stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: UInt8.self).baseAddress)
                stream.avail_in = UInt32(bytes.count)
                return output.withUnsafeMutableBufferPointer { buffer in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = UInt32(buffer.count)
                    return inflate(&stream, Z_FINISH)
                }
            }
            XCTAssertEqual(result, Z_STREAM_END)
            XCTAssertEqual(Data(output.prefix(Int(stream.total_out))), input)
        }
    }
}
