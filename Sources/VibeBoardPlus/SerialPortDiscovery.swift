import Foundation
import IOKit

enum SerialPortDiscovery {
    struct Port {
        let path: String
        let vendor: Int
        let product: Int
        let serial: String
    }
    static func select(_ ports: [Port], serial: String) -> String? {
        ports.first {
            $0.vendor == USBDeviceManager.esp32VendorID && $0.product == USBDeviceManager.esp32SerialProductID &&
            $0.serial.caseInsensitiveCompare(serial) == .orderedSame && !$0.serial.isEmpty
        }?.path
    }
    static func path(for serial: String) -> String? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOSerialBSDClient"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var ports: [Port] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            func property(_ key: String) -> Any? {
                IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                    IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            }
            guard let path = property("IOCalloutDevice") as? String,
                  let vendor = property("idVendor") as? NSNumber,
                  let product = property("idProduct") as? NSNumber,
                  let serial = property("USB Serial Number") as? String else { continue }
            ports.append(Port(path: path, vendor: vendor.intValue, product: product.intValue, serial: serial))
        }
        return select(ports, serial: serial)
    }
}
