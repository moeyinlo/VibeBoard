import XCTest
import Darwin
@testable import VibeBoardPlus

final class SerialConnectionTests: XCTestCase {
    func testAudioFrameKeepsSessionAndFinalFlag() throws {
        var frame = Data([1, 1, 16, 0])
        frame.append(contentsOf: withUnsafeBytes(of: UInt64(42).littleEndian) { Data($0) })
        frame.append(contentsOf: [1, 0, 2, 0, 0x11, 0x22])
        let parsed = try XCTUnwrap(DeviceAudioFrame.parse(frame))
        XCTAssertEqual(parsed.sessionID, 42)
        XCTAssertTrue(parsed.isLast)
        XCTAssertEqual(parsed.payload, Data([0x11, 0x22]))
        frame[12] = 0
        XCTAssertFalse(try XCTUnwrap(DeviceAudioFrame.parse(frame)).isLast)
        frame[2] = 15
        XCTAssertNil(DeviceAudioFrame.parse(frame))
        frame[2] = 16
        frame.removeLast()
        XCTAssertNil(DeviceAudioFrame.parse(frame))
    }

    @MainActor
    func testSerialAudioFrameCarriesMetadata() async throws {
        var master: Int32 = -1, slave: Int32 = -1
        var path = [CChar](repeating: 0, count: 1024)
        XCTAssertEqual(openpty(&master, &slave, &path, nil, nil), 0)
        defer { Darwin.close(master); Darwin.close(slave) }
        let link = SerialDeviceLink()
        defer { link.close() }
        let received = expectation(description: "framed device audio")
        link.onEvent = { event in
            if case .audioFrame(let frame) = event {
                XCTAssertEqual(frame.sessionID, 57)
                XCTAssertTrue(frame.isLast)
                XCTAssertEqual(frame.payload, Data([0xf8, 0xff]))
                received.fulfill()
            }
        }
        XCTAssertTrue(link.open(path: String(cString: path)))
        var frame = Data([1, 1, 16, 0])
        frame.append(contentsOf: withUnsafeBytes(of: UInt64(57).littleEndian) { Data($0) })
        frame.append(contentsOf: [1, 0, 2, 0, 0xf8, 0xff])
        _ = frame.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
        await fulfillment(of: [received], timeout: 3)
    }

    func testPortSelectionTracksUSBIdentityInsteadOfPortNumber() {
        let serial = "AA:BB:CC:DD:EE:FF"
        func port(_ path: String, serial: String, vendor: Int = 0x303A) -> SerialPortDiscovery.Port {
            .init(path: path, vendor: vendor, product: 0x1001, serial: serial)
        }
        XCTAssertEqual(SerialPortDiscovery.select([
            port("/dev/cu.usbmodem3101", serial: "11:22:33:44:55:66"),
            port("/dev/cu.unrelated", serial: serial, vendor: 1),
            port("/dev/cu.usbmodem101", serial: serial.lowercased())
        ], serial: serial), "/dev/cu.usbmodem101")
        XCTAssertNil(SerialPortDiscovery.select([], serial: serial))
    }

    @MainActor
    func testSerialHandshakeAndReopenDiscardIncompleteFrames() async throws {
        var master: Int32 = -1, slave: Int32 = -1
        var path = [CChar](repeating: 0, count: 1024)
        XCTAssertEqual(openpty(&master, &slave, &path, nil, nil), 0)
        defer { Darwin.close(master); Darwin.close(slave) }
        let link = SerialDeviceLink()
        defer { link.close() }
        let received = expectation(description: "device response confirms connection")
        link.onReady = { received.fulfill() }
        link.onDisconnect = { XCTFail("Healthy serial link unexpectedly disconnected") }
        XCTAssertTrue(link.open(path: String(cString: path)))
        let fragment = Data([1, SerialDeviceLink.frameTypeState, 100, 0, 123])
        _ = fragment.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
        await Task.yield()
        link.close()
        XCTAssertFalse(link.isOpen)
        XCTAssertTrue(link.open(path: String(cString: path)))
        let body = Data("{\"event\":\"device_info\"}".utf8)
        var frame = Data([1, SerialDeviceLink.frameTypeState, UInt8(body.count), 0])
        frame.append(body)
        _ = frame.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
        await fulfillment(of: [received], timeout: 3)
        XCTAssertTrue(link.isOpen)
    }
}
