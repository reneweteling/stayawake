import Foundation
import StayAwakeCore

/// `--status` and `--report`. Both only read.
enum SensorReport {
    static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buf)
    }

    private static func t(_ v: Double?) -> String { v.map { String(format: "%.1f C", $0) } ?? "n/a" }

    private static func warmedRead(_ hub: SensorHub, scanSMC: Bool = false) -> SensorReading {
        hub.network.waitForFirstPath()
        Thread.sleep(forTimeInterval: 0.5)
        return hub.read(scanSMC: scanSMC)
    }

    /// The user's stored settings, read only. Falls back to the defaults.
    private static func storedConfig() -> Config {
        // Inside the app bundle .standard is the app's domain. A bare binary
        // from .build reads the app's domain by name.
        let appID = "com.weteling.stayawake"
        let named = Bundle.main.bundleIdentifier == appID ? nil : UserDefaults(suiteName: appID)
        let domains = [UserDefaults.standard, named].compactMap { $0 }
        for d in domains {
            if let data = d.data(forKey: "config"), let c = try? Config.decodeLenient(from: data) { return c }
        }
        return Config()
    }

    /// One engine pass on a fresh state, so the output shows what the rules
    /// compare. A one-shot read has one sample in its window, so its average
    /// equals the instant value; the running app keeps 60 s of samples.
    private static func signals(_ snap: Snapshot, _ config: Config) -> Signals {
        RuleEngine.evaluate(snap, config: config, state: EngineState(),
                            now: Moment(monotonic: ProcessInfo.processInfo.systemUptime, wall: Date())).signals
    }

    /// "now 85.2 C, avg 85.2 C (1 sample), limit 100 C"
    private static func signalLine(_ s: SignalReading, limit: Double) -> String {
        "now \(t(s.instant)), avg \(t(s.smoothed)) (\(s.samples) sample\(s.samples == 1 ? "" : "s")), limit \(String(format: "%.0f C", limit))"
    }

    static func status() -> Int32 {
        let r = warmedRead(SensorHub())
        let s = r.snapshot
        let config = storedConfig()
        let sig = signals(s, config)
        let sd = r.pmset?.sleepDisabled.map { $0 ? "1 (on)" : "0 (off)" } ?? "unknown"
        print("SleepDisabled: \(sd)")
        if let by = r.pmset?.sleepPreventedBy, !by.isEmpty { print("Sleep prevented by: \(by.joined(separator: ", "))") }
        print("CPU \(signalLine(sig.cpu, limit: config.cpuLimit)), source \(sig.cpu.source.rawValue): \(r.cpuSource)")
        print("GPU \(signalLine(sig.gpu, limit: config.gpuLimit)), source \(sig.gpu.source.rawValue): \(r.gpuSource)")
        print("Battery temp \(t(s.batteryTemperature)) (max of \(batteryParts(r))), limit \(String(format: "%.0f C", config.batteryTempLimit)), thermal \(s.thermal.rawValue)")
        print("Battery \(s.batteryPercent.map { "\($0)%" } ?? "n/a"), \(s.powerSource.rawValue)\(s.isCharging ? ", charging" : ""), lid \(s.lidClosed ? "closed" : "open")")
        print("CPU load \(s.cpuLoadPercent.map { String(format: "%.0f%%", $0) } ?? "n/a"), network \(s.networkUsable ? "usable" : "down")")
        return 0
    }

    private static func batteryParts(_ r: SensorReading) -> String {
        "Temperature \(t(r.batteryRaw?.temperature)), VirtualTemperature \(t(r.batteryRaw?.virtualTemperature)), HID gas gauge \(t(r.batteryHID))"
    }

    static func report() -> Int32 {
        let forceSMC = CommandLine.arguments.contains("--smc")
        let r = warmedRead(SensorHub(preference: forceSMC ? .smc : .automatic), scanSMC: true)
        let s = r.snapshot
        print("== Machine")
        print("chip: \(sysctl("machdep.cpu.brand_string"))")
        print("model: \(sysctl("hw.model"))")
        print("chip family (SMC key list): \(r.family.rawValue)")
        print("os: \(ProcessInfo.processInfo.operatingSystemVersionString)")

        print("\n== Readings (as the Snapshot sees them)")
        let config = storedConfig()
        let sig = signals(s, config)
        print("cpuTemperature: \(t(s.cpuTemperature)) via \(r.cpuSource)")
        print("  rule input: \(signalLine(sig.cpu, limit: config.cpuLimit)), source \(sig.cpu.source.rawValue), \(config.smoothingSeconds) s window in the app")
        print("gpuTemperature: \(t(s.gpuTemperature)) via \(r.gpuSource)")
        print("  rule input: \(signalLine(sig.gpu, limit: config.gpuLimit)), source \(sig.gpu.source.rawValue)")
        print("batteryTemperature: \(t(s.batteryTemperature)), max of \(batteryParts(r)), limit \(String(format: "%.0f C", config.batteryTempLimit))")
        print("thermalState: \(s.thermal.rawValue)")
        print("battery: \(s.batteryPercent.map { "\($0)%" } ?? "n/a"), charging: \(s.isCharging), source: \(s.powerSource.rawValue)")
        print("lidClosed: \(s.lidClosed)")
        print("cpuLoad: \(s.cpuLoadPercent.map { String(format: "%.1f%%", $0) } ?? "n/a")")
        print("network usable: \(s.networkUsable)")
        print("SleepDisabled: \(r.pmset?.sleepDisabled.map { $0 ? "1" : "0" } ?? "unknown")")

        print("\n== HID temperature sensors (usage page 0xFF00, usage 5), name = celsius")
        for h in r.hidAll {
            print("\(h.name) = \(h.celsius.map { String(format: "%.2f", $0) } ?? "no event")")
        }

        let c = r.classification
        func names(_ l: [HIDSensor]) -> String { l.isEmpty ? "(none)" : l.map { "\($0.name)=\(String(format: "%.1f", $0.celsius))" }.joined(separator: ", ") }
        print("\n== Classification")
        print("CPU (\(t(c.cpuTemperature)) max): \(names(c.cpu))")
        print("GPU (\(t(c.gpuTemperature)) max): \(names(c.gpu))")
        print("Battery: \(names(c.battery))")
        print("Other: \(names(c.other))")
        print("Invalid: \(names(c.invalid))")

        print("\n== SMC (read only, Tp/Te/Tf/Tg flt keys; <- marks the curated keys for \(r.family.rawValue))")
        if r.smcKeys.isEmpty {
            print("not read (the sensor mode skips SMC, or this chip has no such keys). Force it with: StayAwake --report --smc")
        }
        for line in SensorCombine.table(r.smcKeys, family: r.family) { print(line) }
        func used(_ c: TemperatureChoice) -> String {
            c.used.isEmpty ? "(none)" : c.used.map { "\($0.key)=\(String(format: "%.1f", $0.celsius))" }.joined(separator: ", ")
        }
        print("\n== Selection")
        print("CPU \(t(r.cpu.value)): \(r.cpu.source)")
        print("  SMC keys used: \(used(r.cpu))")
        print("GPU \(t(r.gpu.value)): \(r.gpu.source)")
        print("  SMC keys used: \(used(r.gpu))")

        print("\n== AppleSmartBattery")
        if let b = r.batteryRaw {
            print("IORegistry Temperature raw: \(b.rawTemperature.map(String.init) ?? "n/a") -> \(t(b.temperature)) (hundredths of a degree)")
            print("IORegistry VirtualTemperature raw: \(b.rawVirtualTemperature.map(String.init) ?? "n/a") -> \(t(b.virtualTemperature))")
        }
        if let text = ReadOnlyCommand.ioregBattery() {
            let p = IORegBatteryParser.parse(text)
            print("ioreg text parser: Temperature \(p.rawTemperature.map(String.init) ?? "n/a") -> \(t(p.temperature))")
        }
        return 0
    }
}
