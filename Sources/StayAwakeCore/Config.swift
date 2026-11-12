import Foundation

public enum SensorPreference: String, Codable, CaseIterable, Sendable {
    case automatic, hid, smc, thermalStateOnly
}

public enum AfterTrip: String, Codable, CaseIterable, Sendable {
    case stayOff, rearmOnWake
}

/// Everything the core needs to know about the user's settings, as a plain
/// value. The app maps `UserDefaults` onto this; the core never sees defaults.
/// Temperatures are always Celsius here. `clamped()` pulls every field into
/// the range from the spec.
public struct Config: Codable, Equatable, Sendable {
    // CPU temperature
    public var cpuEnabled = true
    public var cpuLimit: Double = 90
    public var cpuSustainSeconds = 20
    public var cpuClearMargin: Double = 10
    // GPU temperature, same shape as CPU
    public var gpuEnabled = true
    public var gpuLimit: Double = 85
    public var gpuSustainSeconds = 20
    public var gpuClearMargin: Double = 10
    // Battery temperature
    public var batteryTempEnabled = true
    public var batteryTempLimit: Double = 40
    public var batteryTempSustainSeconds = 30
    public var batteryTempClearMargin: Double = 4
    // Thermal pressure
    public var thermalEnabled = true
    public var thermalLimit: ThermalLevel = .serious
    // Battery floor
    public var floorEnabled = true
    public var floorPercent = 20
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

    /// The fixed 5 minute window after which an unchanging reading counts as stuck.
    public static let stuckReadingSeconds: TimeInterval = 300

    public func clamped() -> Config {
        var c = self
        func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }
        c.cpuLimit = clamp(c.cpuLimit, 60, 100)
        c.cpuSustainSeconds = clamp(c.cpuSustainSeconds, 0, 120)
        c.cpuClearMargin = clamp(c.cpuClearMargin, 2, 20)
        c.gpuLimit = clamp(c.gpuLimit, 60, 100)
        c.gpuSustainSeconds = clamp(c.gpuSustainSeconds, 0, 120)
        c.gpuClearMargin = clamp(c.gpuClearMargin, 2, 20)
        c.batteryTempLimit = clamp(c.batteryTempLimit, 30, 50)
        c.batteryTempSustainSeconds = clamp(c.batteryTempSustainSeconds, 0, 120)
        c.batteryTempClearMargin = clamp(c.batteryTempClearMargin, 1, 10)
        if c.thermalLimit == .nominal { c.thermalLimit = .fair }
        c.floorPercent = clamp(c.floorPercent, 5, 60)
        c.lidMinutes = clamp(c.lidMinutes, 10, 480)
        c.idleCpuPercent = clamp(c.idleCpuPercent, 2, 50)
        c.idleMinutes = clamp(c.idleMinutes, 5, 120)
        c.watchedNames = c.watchedNames.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if c.watchedNames.isEmpty { c.watchedNames = ["claude"] }
        c.watchedMinutes = clamp(c.watchedMinutes, 5, 240)
        c.networkMinutes = clamp(c.networkMinutes, 2, 120)
        c.capHours = clamp(c.capHours, 1, 24)
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
        let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Config())) as! [String: Any]
        let known = Set(defaults.keys)
        stored = stored.filter { known.contains($0.key) }
        let merged = defaults.merging(stored) { _, new in new }
        let config = try JSONDecoder().decode(Config.self, from: JSONSerialization.data(withJSONObject: merged))
        return config.clamped()
    }
}
