import Foundation
import IOKit
import StayAwakeCore

// IOHIDEventSystemClient is not in the public headers, but the symbols are
// exported by IOKit and have been stable for years. Read-only.
@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ match: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: AnyObject, _ type: Int64, _ options: Int32, _ timeout: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: AnyObject, _ field: Int32) -> Double

/// All HID temperature services (usage page 0xFF00, usage 5) with their values.
final class HIDSensorReader {
    private let kEventTypeTemperature: Int64 = 15

    /// Every service with a name, plus its value (nil when it gave no event).
    func readAll() -> [(name: String, celsius: Double?)] {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return [] }
        let match: [String: Any] = ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5]
        _ = IOHIDEventSystemClientSetMatching(client, match as CFDictionary)
        guard let services = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [AnyObject] else { return [] }
        var result: [(String, Double?)] = []
        for service in services {
            let name = (IOHIDServiceClientCopyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String) ?? "(unnamed)"
            var value: Double?
            if let event = IOHIDServiceClientCopyEvent(service, kEventTypeTemperature, 0, 0)?.takeRetainedValue() {
                value = IOHIDEventGetFloatValue(event, Int32(kEventTypeTemperature << 16))
            }
            result.append((name, value))
        }
        return result.sorted { $0.0 < $1.0 }
    }

    func sensors() -> [HIDSensor] {
        readAll().compactMap { r in r.celsius.map { HIDSensor(name: r.name, celsius: $0) } }
    }
}
