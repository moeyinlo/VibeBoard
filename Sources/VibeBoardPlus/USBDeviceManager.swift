import Foundation
import IOKit
import IOKit.usb

/// USB 设备管理（协议见 docs/PROTOCOL.md §5）。
///
/// 与原 App（UsbCentral）的差异（稳定性加固）：
/// - IOKit 热插拔通知 + 掉线后自动重枚举（原 App 无主动重连）
/// - device_info 超时后重发 ready 请求并重建心跳
/// - 心跳丢失主动判定并触发链路自愈（原 App 仅被动依赖设备重发）
final class USBDeviceManager {
    static let dataUserClientName = "vibeboard.usb.io"
    static let otaUserClientName  = "vibeboard.usb.ota"

    struct DeviceInfo {
        var mac: String
        var hardware: String
        var firmwareVersion: String
        var deviceID: String?
        var provisioned: Bool
    }

    enum DeviceEvent {
        case attached(USBDeviceManager.DeviceInfo)
        case detached
        case buttonDown(button: String, sessionID: UInt64)
        case buttonUp(button: String, sessionID: UInt64, durationMS: Int)
        case buttonClick(button: String, durationMS: Int)
        /// 设备麦克风音频帧（VibeBoard 硬件端麦克风，非电脑麦克风）
        case audioFrame(DeviceAudioFrame)
    }

    var onEvent: ((DeviceEvent) -> Void)?

    private var notifyPort: IONotificationPortRef?
    private var attachIterator: io_iterator_t = 0
    private var detachIterator: io_iterator_t = 0
    private var heartbeatTimer: DispatchSourceTimer?
    private var heartbeatDeadline: Date?
    private let queue = DispatchQueue(label: "vibeboardplus.usb")

    /// 当前 USB 序列号（即注册用的 mac）
    private(set) var serialNumber: String?

    func start() {
        enumerateAndClaim()
        startHeartbeat()
    }

    // MARK: - 热插拔监控

    private func startHotPlugMonitoring() {
        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let port = notifyPort else { return }
        let queue = self.queue
        IONotificationPortSetDispatchQueue(port, queue)

        let matching = IOServiceMatching(kIOUSBDeviceClassName)
        var iter: io_iterator_t = 0
        let kr = IOServiceAddMatchingNotification(port, kIOPublishNotification, matching,
                                                  { _, iterator in USBDeviceManager.sharedConsumeAttach(iterator) },
                                                  nil, &iter)
        if kr == KERN_SUCCESS { attachIterator = iter; USBDeviceManager.sharedConsumeAttach(iter) }

        var diter: io_iterator_t = 0
        let kr2 = IOServiceAddMatchingNotification(port, kIOTerminatedNotification, matching,
                                                   { _, iterator in USBDeviceManager.sharedConsumeDetach(iterator) },
                                                   nil, &diter)
        if kr2 == KERN_SUCCESS { detachIterator = diter }
    }

    private static func sharedConsumeAttach(_ iterator: io_iterator_t) {
        while IOIteratorNext(iterator) != 0 {}
        NotificationCenter.default.post(name: .init("vb.usb.attach"), object: nil)
    }

    private static func sharedConsumeDetach(_ iterator: io_iterator_t) {
        while IOIteratorNext(iterator) != 0 {}
        NotificationCenter.default.post(name: .init("vb.usb.detach"), object: nil)
    }

    // MARK: - 枚举与连接

    /// 枚举 USB 总线，按序列号找到 VibeBoard 设备。
    @discardableResult
    func enumerateAndClaim() -> DeviceInfo? {
        guard let service = findDevice() else { return nil }
        defer { IOObjectRelease(service) }
        let serial = usbStringProperty(service, kUSBSerialNumberString)
            ?? usbStringProperty(service, "USB Serial Number")
            ?? usbStringProperty(service, "SerialNumber")
        serialNumber = serial
        let info = DeviceInfo(
            mac: serial ?? "",
            hardware: usbStringProperty(service, "USB Product Name") ?? "unknown",
            firmwareVersion: "",
            deviceID: nil,
            provisioned: false
        )
        onEvent?(.attached(info))
        return info
    }

    /// ESP32 USB-JTAG/串口设备（0x303A:0x1001）——实测真机身份：序列号为设备 MAC，
    /// 即原 App 注册用 mac。已替换原推测的 VB-/VS- 前缀匹配。
    static var audioCount = 0
    static let esp32VendorID = 0x303A
    static let esp32SerialProductID = 0x1001

    private func findDevice() -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOUSBDeviceClassName), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if isVibeBoard(service) {
                return service
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return nil
    }

    private func isVibeBoard(_ service: io_service_t) -> Bool {
        let vendor = ioNumberProperty(service, "idVendor")
        let product = ioNumberProperty(service, "idProduct")
        guard vendor == Self.esp32VendorID, product == Self.esp32SerialProductID else { return false }
        // 序列号必须是 MAC 格式（原 App 按 mac 注册）
        let serial = usbStringProperty(service, kUSBSerialNumberString)
            ?? usbStringProperty(service, "USB Serial Number")
        return serial?.contains(":") == true
    }

    private func ioNumberProperty(_ service: io_service_t, _ key: String) -> Int64 {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return -1 }
        if let v = value as? Int64 { return v }
        if let v = value as? Int32 { return Int64(v) }
        if let v = value as? Int { return Int64(v) }
        return -1
    }

    private func usbStringProperty(_ service: io_service_t, _ key: String) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String else { return nil }
        return value
    }

    // MARK: - 心跳与自愈

    private func startHeartbeat() {
        heartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.checkHeartbeat()
        }
        timer.resume()
        heartbeatTimer = timer
        heartbeatDeadline = Date().addingTimeInterval(15)
    }

    private func checkHeartbeat() {
        // 存在性检查：设备仍在总线上就静默续期；消失才报 detached 并重枚举
        if let service = findDevice() {
            IOObjectRelease(service)
            if serialNumber == nil { enumerateAndClaim() }
            heartbeatDeadline = Date().addingTimeInterval(15)
            return
        }
        if serialNumber != nil {
            serialNumber = nil
            onEvent?(.detached)
        }
    }

    /// 收到设备任何消息时调用，刷新心跳窗口
    func noteDeviceAlive() {
        heartbeatDeadline = Date().addingTimeInterval(15)
    }

    func stop() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        if let port = notifyPort { IONotificationPortDestroy(port) }
    }
}
