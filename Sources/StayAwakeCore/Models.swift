import Foundation

public enum PowerSource: String, Codable, Sendable {
    case ac, battery
}

public enum ThermalLevel: String, Codable, Comparable, CaseIterable, Sendable {
    case nominal, fair, serious, critical

    public var rank: Int {
        switch self {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        }
    }

    public static func < (a: ThermalLevel, b: ThermalLevel) -> Bool { a.rank < b.rank }
}

/// Every rule the engine knows. The order of `allCases` is the priority when
/// several rules trip at once: heat and battery first, then the guards, then
/// the "nothing is happening" rules.
public enum RuleID: String, Codable, CaseIterable, Sendable {
    case cpuTemperature, gpuTemperature, batteryTemperature, batteryHeating, thermalPressure, batteryFloor
    case sensorFailure, hardCap, schedule, lidOnBattery, noNetwork, idle, watchedProcess

    public var priority: Int { RuleID.allCases.firstIndex(of: self)! }

    public var title: String {
        switch self {
        case .cpuTemperature: return "CPU temperature"
        case .gpuTemperature: return "GPU temperature"
        case .batteryTemperature: return "Battery temperature"
        case .batteryHeating: return "Battery heating up"
        case .thermalPressure: return "Thermal pressure"
        case .batteryFloor: return "Battery level"
        case .sensorFailure: return "Temperature sensors"
        case .hardCap: return "Time cap"
        case .schedule: return "Schedule"
        case .lidOnBattery: return "Lid closed on battery"
        case .noNetwork: return "Network"
        case .idle: return "Idle"
        case .watchedProcess: return "Watched process"
        }
    }

    /// Short text for the menu bar after a trip.
    public func shortReason(value: Double?, config: Config) -> String {
        func n(_ v: Double?) -> String { v.map { String(Int($0.rounded())) } ?? "" }
        switch self {
        case .cpuTemperature: return "HOT \(n(value))°"
        case .gpuTemperature: return "GPU HOT"
        case .batteryTemperature: return "BATT HOT \(n(value))°"
        case .batteryHeating: return "BATT RISING"
        case .thermalPressure: return "THERMAL"
        case .batteryFloor: return "LOW \(n(value))%"
        case .sensorFailure: return "SENSOR"
        case .hardCap: return "CAP \(config.capHours)h"
        case .schedule: return "SCHEDULE"
        case .lidOnBattery: return "LID \(config.lidMinutes)m"
        case .noNetwork: return "NO NET"
        case .idle: return "IDLE"
        case .watchedProcess: return "NO PROCESS"
        }
    }
}

/// Where a CPU or GPU reading came from.
public enum TemperatureSource: String, Codable, Sendable {
    /// Mean of the curated SMC keys of a known chip.
    case smc
    /// HID die sensors: the unknown-chip path, or SMC gave nothing this sample.
    case hid
    /// Max over every SMC key with the family prefixes, last resort.
    case fallback
    /// The engine repeated the last SMC value because SMC skipped this sample.
    case held
    case none
}

/// What the sensors said at one moment. Built by the app, never by the core.
public struct Snapshot: Codable, Equatable, Sendable {
    /// Instant CPU reading, see `SensorCombine.choose`. The engine smooths it.
    public var cpuTemperature: Double?
    public var gpuTemperature: Double?
    public var cpuSource: TemperatureSource
    public var gpuSource: TemperatureSource
    /// Hottest of the battery sensors, see `SensorCombine.battery`.
    public var batteryTemperature: Double?
    public var thermal: ThermalLevel
    public var batteryPercent: Int?
    public var powerSource: PowerSource
    public var isCharging: Bool
    public var lidClosed: Bool
    /// All-core average, 0 to 100.
    public var cpuLoadPercent: Double?
    public var watchedProcessRunning: Bool?
    public var networkUsable: Bool
    /// True when the app saw a wake notification since the last snapshot.
    public var didWake: Bool

    public init(cpuTemperature: Double? = 50, gpuTemperature: Double? = 45,
                cpuSource: TemperatureSource = .smc, gpuSource: TemperatureSource = .smc,
                batteryTemperature: Double? = 30,
                thermal: ThermalLevel = .nominal, batteryPercent: Int? = 80,
                powerSource: PowerSource = .battery, isCharging: Bool = false, lidClosed: Bool = false,
                cpuLoadPercent: Double? = 40, watchedProcessRunning: Bool? = true,
                networkUsable: Bool = true, didWake: Bool = false) {
        self.cpuTemperature = cpuTemperature
        self.gpuTemperature = gpuTemperature
        self.cpuSource = cpuSource
        self.gpuSource = gpuSource
        self.batteryTemperature = batteryTemperature
        self.thermal = thermal
        self.batteryPercent = batteryPercent
        self.powerSource = powerSource
        self.isCharging = isCharging
        self.lidClosed = lidClosed
        self.cpuLoadPercent = cpuLoadPercent
        self.watchedProcessRunning = watchedProcessRunning
        self.networkUsable = networkUsable
        self.didWake = didWake
    }
}

/// The two clocks. Durations use `monotonic` (seconds, any origin), the
/// schedule uses `wall` in `timeZone`. The core never reads either itself.
public struct Moment: Equatable, Sendable {
    public var monotonic: TimeInterval
    public var wall: Date
    public var timeZone: TimeZone

    public init(monotonic: TimeInterval, wall: Date, timeZone: TimeZone = .current) {
        self.monotonic = monotonic
        self.wall = wall
        self.timeZone = timeZone
    }

    public func advanced(by seconds: TimeInterval) -> Moment {
        Moment(monotonic: monotonic + seconds, wall: wall.addingTimeInterval(seconds), timeZone: timeZone)
    }
}

/// Armed is what the user asked for, holding is whether the Mac is actually
/// kept awake right now.
public enum Phase: String, Codable, Sendable {
    case off, waiting, holding, tripped
}

public enum ArmDuration: String, Codable, CaseIterable, Sendable {
    case untilTrip, oneHour, twoHours, fourHours, untilScheduleEnd

    public var seconds: TimeInterval? {
        switch self {
        case .oneHour: return 3600
        case .twoHours: return 7200
        case .fourHours: return 14400
        case .untilTrip, .untilScheduleEnd: return nil
        }
    }
}

public struct TripInfo: Codable, Equatable, Sendable {
    public var rule: RuleID
    public var value: Double?
    public var limit: Double?
    /// One line for the popover and the event log.
    public var message: String
    public var shortReason: String

    public init(rule: RuleID, value: Double?, limit: Double?, message: String, shortReason: String) {
        self.rule = rule
        self.value = value
        self.limit = limit
        self.message = message
        self.shortReason = shortReason
    }
}

/// User-facing events the app turns into notifications or UI.
public enum Alert: String, Codable, Equatable, Sendable {
    /// Power went from AC to battery while armed or holding.
    case unpluggedWhileHolding
    /// Turned on again by itself after a low-battery stop, because the Mac was plugged in.
    case rearmedOnPower
}

public enum Action: String, Codable, Sendable {
    case none
    /// Ask the helper to hold (disablesleep 1).
    case hold
    /// Ask the helper to release (disablesleep 0).
    case release
}

/// How close one rule is to tripping.
public struct RuleMargin: Codable, Equatable, Sendable {
    public var rule: RuleID
    /// 1 means far away, 0 means at the limit.
    public var fraction: Double
    /// Time until the rule trips, when that can be known.
    public var seconds: TimeInterval?
    public var detail: String

    public init(rule: RuleID, fraction: Double, seconds: TimeInterval?, detail: String) {
        self.rule = rule
        self.fraction = max(0, min(1, fraction))
        self.seconds = seconds
        self.detail = detail
    }
}

public struct Decision: Equatable, Sendable {
    public var state: EngineState
    public var phase: Phase
    public var action: Action
    /// Rules that fail right now, highest priority first.
    public var failing: [TripInfo]
    /// Set only on the evaluation that moved holding to tripped.
    public var trip: TripInfo?
    public var alerts: [Alert]
    /// True when an "arm for" timer ended this hold.
    public var timerEnded: Bool
    public var margins: [RuleMargin]
    public var nextToTrip: [RuleMargin]
    public var warnings: [RuleID]
    public var timeLeft: TimeInterval?
    public var scheduleOpen: Bool
    public var nextScheduleOpen: Date?
    /// The values the temperature rules actually compared, with the instant ones next to them.
    public var signals: Signals = .empty

    public var wantsAwake: Bool { phase == .holding }
}
