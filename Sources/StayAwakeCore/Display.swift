import Foundation

public enum TemperatureUnit: String, Codable, CaseIterable, Sendable {
    case celsius, fahrenheit

    /// Display only. Limits and readings are stored in Celsius.
    public func convert(_ celsius: Double) -> Double {
        self == .celsius ? celsius : celsius * 9 / 5 + 32
    }

    public var symbol: String { self == .celsius ? "°C" : "°F" }
}

public enum MenuBarReadout: String, Codable, CaseIterable, Sendable {
    case none, temperature, battery, both
}

/// Text for the popover and the menu bar. Pure, so it is tested.
public enum Readout {
    public static func number(_ v: Double) -> String { String(Int(v.rounded())) }

    /// "1 h 12 min", "42 min", "45 s". Rounds to the minute above 90 seconds.
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 90 { return "\(s) s" }
        let minutes = Int((Double(s) / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /// "CPU 58 °C / 80". The limit is shown in the same unit, without the unit.
    public static func temperature(_ label: String, _ celsius: Double?, limit: Double, unit: TemperatureUnit) -> String {
        guard let celsius else { return "\(label) n/a / \(number(unit.convert(limit)))" }
        return "\(label) \(number(unit.convert(celsius))) \(unit.symbol) / \(number(unit.convert(limit)))"
    }

    public static func cpu(_ snap: Snapshot, _ config: Config, unit: TemperatureUnit = .celsius) -> String {
        temperature("CPU", snap.cpuTemperature, limit: config.cpuLimit, unit: unit)
    }

    public static func gpu(_ snap: Snapshot, _ config: Config, unit: TemperatureUnit = .celsius) -> String {
        temperature("GPU", snap.gpuTemperature, limit: config.gpuLimit, unit: unit)
    }

    public static func batteryTemperature(_ snap: Snapshot, _ config: Config, unit: TemperatureUnit = .celsius) -> String {
        temperature("Battery", snap.batteryTemperature, limit: config.batteryTempLimit, unit: unit)
    }

    /// "Battery 71% / stops at 20%"
    public static func batteryLevel(_ snap: Snapshot, _ config: Config) -> String {
        let p = snap.batteryPercent.map { "\($0)%" } ?? "n/a"
        return "Battery \(p) / stops at \(config.floorPercent)%"
    }

    /// The part after the label, for rows that show the label separately.
    public static func value(_ full: String, label: String) -> String {
        full.hasPrefix(label + " ") ? String(full.dropFirst(label.count + 1)) : full
    }

    public static func clock(_ date: Date, in tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = tz
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// "07:00" for today, "Tue 07:00" for another day.
    public static func opensAt(_ date: Date, now: Date, in tz: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        if cal.isDate(date, inSameDayAs: now) { return clock(date, in: tz) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = tz
        f.dateFormat = "EEE HH:mm"
        return f.string(from: date)
    }

    /// The smallest time left among the rules that have an estimate, with its name.
    public static func limitingTime(_ margins: [RuleMargin], timerLeft: TimeInterval?) -> (label: String, seconds: TimeInterval)? {
        let names: [RuleID: String] = [.hardCap: "time cap", .schedule: "schedule end",
                                       .lidOnBattery: "lid limit", .batteryFloor: "battery floor"]
        var best: (String, TimeInterval)?
        for m in margins {
            guard let name = names[m.rule], let s = m.seconds else { continue }
            if best == nil || s < best!.1 { best = (name, s) }
        }
        if let t = timerLeft, best == nil || t < best!.1 { best = ("timer", max(0, t)) }
        return best.map { (label: $0.0, seconds: $0.1) }
    }

    /// One line for a margin: "Lid on battery · 42 min left" or the sensor detail.
    public static func marginLine(_ m: RuleMargin) -> String {
        if let s = m.seconds { return "\(m.detail) · \(duration(s)) left" }
        return m.detail
    }

    /// Whether a margin says anything useful (not "far away, not started").
    public static func isMeaningful(_ m: RuleMargin) -> Bool { m.seconds != nil || m.fraction < 1 }
}

public enum StatusKind: String, Equatable, Sendable {
    case off, waiting, holding, warning, tripped, setup
}

public enum StatusTone: String, Equatable, Sendable {
    case normal, amber, red
}

/// What the menu bar item shows. Section 3 of the spec as one pure function.
public struct MenuBarStatus: Equatable, Sendable {
    public var kind: StatusKind
    public var symbol: String
    public var title: String
    public var tone: StatusTone
    public var tooltip: String

    public init(kind: StatusKind, symbol: String, title: String = "", tone: StatusTone = .normal, tooltip: String) {
        self.kind = kind
        self.symbol = symbol
        self.title = title
        self.tone = tone
        self.tooltip = tooltip
    }

    public struct Input: Sendable {
        public var phase: Phase
        /// Non-nil when the backend cannot run pmset yet; the text says what to do.
        public var setupMessage: String?
        public var snapshot: Snapshot
        public var decision: Decision?
        public var lastTrip: TripInfo?
        public var trippedAt: Date?
        public var heldFor: TimeInterval?
        public var now: Date
        public var config: Config
        public var readout: MenuBarReadout
        public var unit: TemperatureUnit
        public var timeZone: TimeZone

        public init(phase: Phase, setupMessage: String? = nil, snapshot: Snapshot = Snapshot(), decision: Decision? = nil,
                    lastTrip: TripInfo? = nil, trippedAt: Date? = nil, heldFor: TimeInterval? = nil, now: Date = Date(),
                    config: Config = Config(), readout: MenuBarReadout = .both, unit: TemperatureUnit = .celsius,
                    timeZone: TimeZone = .current) {
            self.phase = phase; self.setupMessage = setupMessage; self.snapshot = snapshot; self.decision = decision
            self.lastTrip = lastTrip; self.trippedAt = trippedAt; self.heldFor = heldFor; self.now = now
            self.config = config; self.readout = readout; self.unit = unit; self.timeZone = timeZone
        }
    }

    public static let setupSymbol = "lock.slash"

    public static func make(_ i: Input) -> MenuBarStatus {
        switch i.phase {
        case .tripped:
            let trip = i.lastTrip
            let at = i.trippedAt.map { Readout.clock($0, in: i.timeZone) }
            let text = trip?.message ?? "a rule tripped"
            return MenuBarStatus(kind: .tripped, symbol: "exclamationmark.triangle.fill",
                                 title: trip?.shortReason ?? "TRIPPED", tone: .red,
                                 tooltip: "Sleep restored\(at.map { " at \($0)" } ?? ""): \(text)")
        case .off:
            if let setup = i.setupMessage {
                return MenuBarStatus(kind: .setup, symbol: setupSymbol, title: "SETUP", tooltip: setup)
            }
            return MenuBarStatus(kind: .off, symbol: "moon.zzz", tooltip: "StayAwake: off")
        case .waiting:
            if let opens = i.decision?.nextScheduleOpen, i.decision?.scheduleOpen == false {
                let t = Readout.opensAt(opens, now: i.now, in: i.timeZone)
                return MenuBarStatus(kind: .waiting, symbol: "clock", title: t, tooltip: "Armed, waiting for \(t)")
            }
            let why = i.decision?.failing.first?.message ?? "conditions"
            return MenuBarStatus(kind: .waiting, symbol: "clock", tooltip: "Armed, waiting: \(why)")
        case .holding:
            let readout = readoutText(i)
            let held = i.heldFor.map { "Awake for \(Readout.duration($0))" } ?? "Awake"
            if let warning = warningText(i) {
                let red = i.decision?.margins.contains { $0.fraction <= 0 && i.decision!.warnings.contains($0.rule) } ?? false
                return MenuBarStatus(kind: .warning, symbol: "cup.and.saucer.fill", title: readout,
                                     tone: red ? .red : .amber, tooltip: warning)
            }
            var parts = [held]
            if let p = i.snapshot.batteryPercent { parts.append("battery \(p)%") }
            if let c = i.snapshot.cpuTemperature { parts.append("CPU \(Readout.number(i.unit.convert(c)))°") }
            return MenuBarStatus(kind: .holding, symbol: "cup.and.saucer.fill", title: readout,
                                 tooltip: parts.joined(separator: " · "))
        }
    }

    private static func readoutText(_ i: Input) -> String {
        var parts: [String] = []
        if i.readout == .temperature || i.readout == .both, let c = i.snapshot.cpuTemperature {
            parts.append("\(Readout.number(i.unit.convert(c)))°")
        }
        if i.readout == .battery || i.readout == .both, let p = i.snapshot.batteryPercent {
            parts.append("\(p)%")
        }
        return parts.joined(separator: " ")
    }

    /// Tooltip for the first rule in the warning band, e.g. "Battery at 24%, trips at 20%".
    private static func warningText(_ i: Input) -> String? {
        guard let d = i.decision, let first = d.nextToTrip.first(where: { d.warnings.contains($0.rule) }) else { return nil }
        let s = i.snapshot, c = i.config
        func temp(_ name: String, _ v: Double?, _ limit: Double) -> String {
            "\(name) at \(v.map { Readout.number(i.unit.convert($0)) } ?? "n/a") \(i.unit.symbol), trips at \(Readout.number(i.unit.convert(limit))) \(i.unit.symbol)"
        }
        switch first.rule {
        case .cpuTemperature: return temp("CPU", s.cpuTemperature, c.cpuLimit)
        case .gpuTemperature: return temp("GPU", s.gpuTemperature, c.gpuLimit)
        case .batteryTemperature: return temp("Battery", s.batteryTemperature, c.batteryTempLimit)
        case .batteryFloor: return "Battery at \(s.batteryPercent.map(String.init) ?? "n/a")%, trips at \(c.floorPercent)%"
        default: return first.seconds.map { "\(first.detail): trips in \(Readout.duration($0))" } ?? first.detail
        }
    }
}
