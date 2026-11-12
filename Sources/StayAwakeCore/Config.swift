import Foundation

public enum SensorPreference: String, Codable, CaseIterable, Sendable {
    case automatic, hid, smc, thermalStateOnly
}

public enum AfterTrip: String, Codable, CaseIterable, Sendable {
    case stayOff, rearmOnWake
}

/// Allowed ranges of the settings that the Settings window shows with
/// steppers. `Config.clamped()` and the UI both read them from here.
public enum ConfigRange {
    public static let cpuLimit: ClosedRange<Double> = 60...110
    public static let gpuLimit: ClosedRange<Double> = 60...110
    public static let batteryTempLimit: ClosedRange<Double> = 30...50
    public static let sustainSeconds: ClosedRange<Int> = 0...300
    public static let clearMargin: ClosedRange<Double> = 2...20
    public static let batteryClearMargin: ClosedRange<Double> = 1...10
    public static let thermalSustainSeconds: ClosedRange<Int> = 0...600
    public static let batteryHeatingRise: ClosedRange<Double> = 0.5...10
    public static let smoothingSeconds: ClosedRange<Int> = 0...300
    /// Hard time cap in hours. The helper enforces 12 h per hold regardless.
    public static let capHours: ClosedRange<Int> = 1...12
}

/// Everything the core needs to know about the user's settings, as a plain
/// value. The app maps `UserDefaults` onto this; the core never sees defaults.
/// Temperatures are always Celsius here. `clamped()` pulls every field into
/// the range from the spec. The defaults are the Balanced preset.
public struct Config: Codable, Equatable, Sendable {
    /// Bumped when stored settings need more than "missing keys take their
    /// default". See `decodeLenient`.
    public static let currentVersion = 4
    public var configVersion = Config.currentVersion
    // CPU temperature, compared as the rolling average of the curated SMC keys
    public var cpuEnabled = true
    public var cpuLimit: Double = 100
    public var cpuSustainSeconds = 120
    public var cpuClearMargin: Double = 10
    /// Width of the rolling average for CPU and GPU. 0 compares each sample as it is.
    public var smoothingSeconds = 60
    // GPU temperature, same shape as CPU
    public var gpuEnabled = true
    public var gpuLimit: Double = 95
    public var gpuSustainSeconds = 120
    public var gpuClearMargin: Double = 10
    // Battery temperature, the hottest battery sensor. The main bag-safety rule.
    public var batteryTempEnabled = true
    public var batteryTempLimit: Double = 43
    public var batteryTempSustainSeconds = 60
    public var batteryTempClearMargin: Double = 3
    // Battery heating up: lid closed on battery, rise inside a 5 minute window
    public var batteryHeatingEnabled = false
    public var batteryHeatingRise: Double = 2
    // Thermal pressure. Critical always trips at once; lower levels at or
    // above the limit trip after `thermalSustainSeconds`.
    public var thermalEnabled = true
    public var thermalLimit: ThermalLevel = .serious
    public var thermalSustainSeconds = 300
    // Battery floor
    public var floorEnabled = true
    public var floorPercent = 40
    // Lid closed on battery
    public var lidEnabled = true
    public var lidMinutes = 90
    // Idle (lid closed only)
    public var idleEnabled = true
    public var idleCpuPercent = 10
    public var idleMinutes = 15
    // Watched process
    public var watchedEnabled = false
    public var watchedNames: [String] = ["claude"]
    public var watchedMinutes = 20
    // Network
    public var networkEnabled = true
    public var networkMinutes = 15
    // Hard cap
    public var capEnabled = true
    public var capHours = 8
    // Sensor failure (cannot be switched off)
    public var sensorFailureSeconds = 60
    public var sensorPreference: SensorPreference = .automatic
    // Schedule
    public var schedule = Schedule.default
    // General behaviour
    public var afterTrip: AfterTrip = .stayOff
    public var armDefault: ArmDuration = .untilTrip
    // Notifications tab
    public var notifyOnTrip = true
    /// Minutes before a trip to warn. 0 means off.
    public var headsUpMinutes = 5
    public var notifyOnManualArm = false
    /// Alert when the power cable comes out while armed or holding.
    public var alertOnUnplug = true
    /// Days to keep the event log. 0 means no log.
    public var logRetentionDays = 30
    /// Minutes between sensor samples in the log while holding. 0 means off.
    public var sampleMinutes = 5
    // Advanced
    public var holdingIntervalSeconds = 15
    public var offIntervalSeconds = 60
    public var leaseSeconds = 60

    public init() {}

    /// The fixed 5 minute window after which an unchanging CPU or GPU reading counts
    /// as stuck. Battery temperature is exempt, see `RuleEngine.sensor`.
    public static let stuckReadingSeconds: TimeInterval = 300
    /// The window of the battery heating-up rule.
    public static let batteryHeatingWindowSeconds: TimeInterval = 300

    public func clamped() -> Config {
        var c = self
        func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }
        func clamp<T: Comparable>(_ v: T, _ r: ClosedRange<T>) -> T { min(max(v, r.lowerBound), r.upperBound) }
        typealias R = ConfigRange
        c.configVersion = Config.currentVersion
        c.cpuLimit = clamp(c.cpuLimit, R.cpuLimit)
        c.cpuSustainSeconds = clamp(c.cpuSustainSeconds, R.sustainSeconds)
        c.cpuClearMargin = clamp(c.cpuClearMargin, R.clearMargin)
        c.gpuLimit = clamp(c.gpuLimit, R.gpuLimit)
        c.gpuSustainSeconds = clamp(c.gpuSustainSeconds, R.sustainSeconds)
        c.gpuClearMargin = clamp(c.gpuClearMargin, R.clearMargin)
        c.batteryTempLimit = clamp(c.batteryTempLimit, R.batteryTempLimit)
        c.batteryTempSustainSeconds = clamp(c.batteryTempSustainSeconds, R.sustainSeconds)
        c.batteryTempClearMargin = clamp(c.batteryTempClearMargin, R.batteryClearMargin)
        c.batteryHeatingRise = clamp(c.batteryHeatingRise, R.batteryHeatingRise)
        if c.thermalLimit == .nominal { c.thermalLimit = .fair }
        c.thermalSustainSeconds = clamp(c.thermalSustainSeconds, R.thermalSustainSeconds)
        c.smoothingSeconds = clamp(c.smoothingSeconds, R.smoothingSeconds)
        c.floorPercent = clamp(c.floorPercent, 5, 60)
        c.lidMinutes = clamp(c.lidMinutes, 10, 480)
        c.idleCpuPercent = clamp(c.idleCpuPercent, 2, 50)
        c.idleMinutes = clamp(c.idleMinutes, 5, 120)
        c.watchedNames = c.watchedNames.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if c.watchedNames.isEmpty { c.watchedNames = ["claude"] }
        c.watchedMinutes = clamp(c.watchedMinutes, 5, 240)
        c.networkMinutes = clamp(c.networkMinutes, 2, 120)
        c.capHours = clamp(c.capHours, R.capHours)
        c.sensorFailureSeconds = clamp(c.sensorFailureSeconds, 30, 300)
        c.schedule = c.schedule.normalized()
        c.headsUpMinutes = clamp(c.headsUpMinutes, 0, 30)
        c.logRetentionDays = c.logRetentionDays == 0 ? 0 : clamp(c.logRetentionDays, 7, 365)
        c.sampleMinutes = c.sampleMinutes == 0 ? 0 : clamp(c.sampleMinutes, 1, 60)
        c.holdingIntervalSeconds = clamp(c.holdingIntervalSeconds, 5, 60)
        c.offIntervalSeconds = clamp(c.offIntervalSeconds, 30, 300)
        c.leaseSeconds = clamp(c.leaseSeconds, 30, 120)
        return c
    }

    /// Reads stored settings of any age: keys that are missing take their
    /// default, keys this version does not know are ignored, and the result
    /// is clamped. This is the migration path for older settings.
    public static func decodeLenient(from data: Data) throws -> Config {
        guard var stored = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Config must be a JSON object"))
        }
        stored = migrate(stored)
        let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Config())) as! [String: Any]
        let known = Set(defaults.keys)
        stored = stored.filter { known.contains($0.key) }
        let merged = defaults.merging(stored) { _, new in new }
        let config = try JSONDecoder().decode(Config.self, from: JSONSerialization.data(withJSONObject: merged))
        return config.clamped()
    }

    /// Version 1 compared the instant max of the CPU keys against 90 C for
    /// 20 s, which trips during normal work on an M2 Max. Version 2 compared
    /// a 60 s average against 102 C (CPU) and 100 C (GPU). Version 3 sets
    /// Balanced to 100 C and 95 C. A rule the user never touched (still at
    /// the default of the version it was stored with; a missing key counts as
    /// the default) moves to the new defaults. Edited values stay as they are.
    /// Version 4 raises the battery floor default from 20 to 40.
    static func migrate(_ input: [String: Any]) -> [String: Any] {
        var stored = input
        let version = (stored["configVersion"] as? NSNumber)?.intValue ?? 1
        guard version < 4 else { return stored }
        if version < 3 { stored = migrateHeat(stored, version: version) }
        // Version 4 raised the battery floor from 20 to 40. A floor still at 20 (or
        // missing) was never touched, so it takes the new default. Edited values stay.
        if ((stored["floorPercent"] as? NSNumber)?.intValue ?? 20) == 20 { stored.removeValue(forKey: "floorPercent") }
        stored["configVersion"] = Config.currentVersion
        return stored
    }

    /// The version 1 and 2 heat limit migration, see `migrate`.
    private static func migrateHeat(_ input: [String: Any], version: Int) -> [String: Any] {
        var stored = input
        func number(_ key: String, default d: Double) -> Double { (stored[key] as? NSNumber)?.doubleValue ?? d }
        // Untouched: drop the keys so the new defaults apply. Edited: write
        // the missing ones as their version 1 default, so a stored limit
        // keeps the wait it was used with.
        func reset(_ keys: [String], ifAt old: [Double]) {
            if zip(keys, old).allSatisfy({ number($0.0, default: $0.1) == $0.1 }) {
                keys.forEach { stored.removeValue(forKey: $0) }
            } else {
                for (k, v) in zip(keys, old) where stored[k] == nil { stored[k] = v }
            }
        }
        if version < 2 {
            reset(["cpuLimit", "cpuSustainSeconds"], ifAt: [90, 20])
            reset(["gpuLimit", "gpuSustainSeconds"], ifAt: [85, 20])
            reset(["batteryTempLimit", "batteryTempSustainSeconds"], ifAt: [40, 30])
            reset(["batteryTempClearMargin"], ifAt: [4])
        } else {
            reset(["cpuLimit", "cpuSustainSeconds"], ifAt: [102, 120])
            reset(["gpuLimit", "gpuSustainSeconds"], ifAt: [100, 120])
        }
        return stored
    }
}
