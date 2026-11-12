import Foundation
import IOKit
import IOKit.ps
import Network
import StayAwakeCore

/// Battery level, charging and power source through IOPS (public API).
struct PowerSourceReading {
    var percent: Int?
    var isCharging: Bool
    var source: PowerSource
    var hasBattery: Bool

    static func read() -> PowerSourceReading {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        var percent: Int?
        var charging = false
        var hasBattery = false
        for item in list {
            guard let d = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any] else { continue }
            guard (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            hasBattery = true
            if let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                percent = Int((Double(cur) / Double(max) * 100).rounded())
            }
            charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
        }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeRetainedValue() as String?
        let source: PowerSource = providing == kIOPSACPowerValue ? .ac : .battery
        return PowerSourceReading(percent: percent, isCharging: charging, source: source, hasBattery: hasBattery)
    }
}

enum IORegistryReader {
    /// IOPMrootDomain AppleClamshellState. True when the lid is closed.
    static func lidClosed() -> Bool? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IOPMrootDomain")
        let service = entry != 0 ? entry : IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let v = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { return nil }
        return (v as? Bool)
    }

    /// AppleSmartBattery properties straight from the registry.
    static func battery() -> BatterySample? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func int(_ k: String) -> Int? {
            (IORegistryEntryCreateCFProperty(service, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
        }
        func bool(_ k: String) -> Bool? {
            IORegistryEntryCreateCFProperty(service, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
        }
        return BatterySample(rawTemperature: int("Temperature"), rawVirtualTemperature: int("VirtualTemperature"),
                             currentCapacity: int("CurrentCapacity"), maxCapacity: int("MaxCapacity"),
                             isCharging: bool("IsCharging"), externalConnected: bool("ExternalConnected"))
    }
}

/// Runs a fixed read-only command. Only `pmset -g` variants and `ioreg -rn
/// AppleSmartBattery` exist here, so nothing can change a power setting.
enum ReadOnlyCommand {
    static func pmsetG() -> String? { run("/usr/bin/pmset", ["-g"]) }
    static func ioregBattery() -> String? { run("/usr/sbin/ioreg", ["-rn", "AppleSmartBattery"]) }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

func thermalLevel(_ state: ProcessInfo.ThermalState) -> ThermalLevel {
    switch state {
    case .nominal: return .nominal
    case .fair: return .fair
    case .serious: return .serious
    case .critical: return .critical
    @unknown default: return .serious
    }
}

/// All-core CPU load from host_processor_info tick deltas.
final class CPULoadSampler {
    private var previous: [UInt32] = []

    /// Percent busy since the last call. Nil on the first call.
    func sample() -> Double? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)) }
        let stride = Int(CPU_STATE_MAX)
        var now: [UInt32] = []
        for cpu in 0..<Int(count) {
            for s in 0..<stride { now.append(UInt32(bitPattern: info[cpu * stride + s])) }
        }
        defer { previous = now }
        guard previous.count == now.count, !now.isEmpty else { return nil }
        var busy: UInt64 = 0, total: UInt64 = 0
        for cpu in 0..<Int(count) {
            let b = cpu * stride
            let user = UInt64(now[b + Int(CPU_STATE_USER)] &- previous[b + Int(CPU_STATE_USER)])
            let sys = UInt64(now[b + Int(CPU_STATE_SYSTEM)] &- previous[b + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(now[b + Int(CPU_STATE_NICE)] &- previous[b + Int(CPU_STATE_NICE)])
            let idle = UInt64(now[b + Int(CPU_STATE_IDLE)] &- previous[b + Int(CPU_STATE_IDLE)])
            busy += user + sys + nice
            total += user + sys + nice + idle
        }
        return total == 0 ? nil : Double(busy) / Double(total) * 100
    }
}

/// Network reachability through NWPathMonitor.
final class NetworkWatcher: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "stayawake.network")
    private let lock = NSLock()
    private var status: NWPath.Status = .requiresConnection
    private var received = false
    /// Called on the monitor queue whenever the path changes.
    var onChange: (@Sendable () -> Void)?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock(); self.status = path.status; self.received = true; self.lock.unlock()
            self.onChange?()
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }

    /// Waits up to `timeout` seconds for the first path update.
    func waitForFirstPath(timeout: TimeInterval = 1) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            lock.lock(); let ok = received; lock.unlock()
            if ok { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    var usable: Bool {
        lock.lock(); defer { lock.unlock() }
        return status == .satisfied
    }
}
