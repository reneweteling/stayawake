import Foundation
import IOKit
import StayAwakeCore

/// Fallback temperature source: the AppleSMC user client, read only.
/// Temperature keys have type "flt ". Which keys count is decided in core
/// (SMCTemperatureKeys, per chip family); this only reads.
final class SMCReader {
    private struct Vers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
    private struct PLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
    private struct KeyInfo { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0
        // Swift does not pad the tail of a nested struct like C does.
        var pad: (UInt8, UInt8, UInt8) = (0, 0, 0) }
    private struct KeyData {
        var key: UInt32 = 0
        var vers = Vers()
        var pLimit = PLimit()
        var keyInfo = KeyInfo()
        var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }

    private var connection: io_connect_t = 0

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard kr == KERN_SUCCESS else { return nil }
        guard MemoryLayout<KeyData>.size == 80 else { return nil }
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    private func call(_ input: KeyData) -> KeyData? {
        var input = input
        var output = KeyData()
        var outSize = MemoryLayout<KeyData>.size
        let r = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<KeyData>.size, &output, &outSize)
        return (r == KERN_SUCCESS && output.result == 0) ? output : nil
    }

    private func fourCC(_ s: String) -> UInt32 { s.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) } }
    private func string(_ v: UInt32) -> String {
        String(bytes: [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)], encoding: .ascii) ?? "????"
    }

    private func keyName(at index: UInt32) -> String? {
        var d = KeyData()
        d.data8 = 8
        d.data32 = index
        return call(d).map { string($0.key) }
    }

    private func readFloat(_ key: String) -> Double? {
        var d = KeyData()
        d.key = fourCC(key)
        d.data8 = 9
        guard let info = call(d)?.keyInfo, string(info.dataType) == "flt ", info.dataSize == 4 else { return nil }
        d.keyInfo = info
        d.data8 = 5
        guard let out = call(d) else { return nil }
        var raw = out.bytes.0
        let bits = withUnsafeBytes(of: &raw) { $0.load(as: UInt32.self) }
        return Double(Float(bitPattern: bits))
    }

    private func keyCount() -> UInt32 {
        var d = KeyData()
        d.key = fourCC("#KEY")
        d.data8 = 9
        guard let info = call(d)?.keyInfo else { return 0 }
        d.keyInfo = info
        d.data8 = 5
        guard let out = call(d) else { return 0 }
        var raw = out.bytes.0
        let be = withUnsafeBytes(of: &raw) { $0.load(as: UInt32.self) }
        return UInt32(bigEndian: be)
    }

    private var keyCache: [String] = []
    private var scanned = false

    /// Names of all flt keys with one of the prefixes. The key table is walked once.
    private func keys(prefixes: [String]) -> [String] {
        if !scanned {
            scanned = true
            for i in 0..<keyCount() {
                if let key = keyName(at: i), key.hasPrefix("T"), readFloat(key) != nil { keyCache.append(key) }
            }
        }
        return keyCache.filter { k in prefixes.contains { k.hasPrefix($0) } }
    }

    /// Raw values of the named keys. Missing or non-flt keys are left out;
    /// plausibility is decided in core (SensorCombine).
    func read(keys: [String]) -> [SMCKey] {
        keys.compactMap { k in readFloat(k).map { SMCKey(key: k, celsius: $0) } }
    }

    /// Raw values of every flt key with one of the prefixes.
    func scan(prefixes: [String]) -> [SMCKey] { read(keys: keys(prefixes: prefixes)) }
}
