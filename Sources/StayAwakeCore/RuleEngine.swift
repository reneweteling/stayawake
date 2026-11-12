import Foundation

/// Per sensor bookkeeping for sustain, validity and stuck readings.
public struct SensorTracker: Codable, Equatable, Sendable {
    public var exceededSince: TimeInterval?
    public var invalidSince: TimeInterval?
    public var lastValue: Double?
    public var lastChange: TimeInterval?
    public init() {}
}

/// Everything the engine remembers between evaluations. A plain value: the
/// app keeps it, passes it in and stores the new one from the `Decision`.
public struct EngineState: Codable, Equatable, Sendable {
    public var phase: Phase = .off
    public var heldSince: TimeInterval?
    public var armDeadlineMonotonic: TimeInterval?
    public var armDeadlineWall: Date?
    public var lastTrip: TripInfo?
    /// Rules that tripped and have not yet passed their clears-at level.
    public var latched: Set<RuleID> = []
    public var cpu = SensorTracker()
    public var gpu = SensorTracker()
    public var batteryTemp = SensorTracker()
    public var lidSince: TimeInterval?
    public var idleSince: TimeInterval?
    public var noProcessSince: TimeInterval?
    public var noNetworkSince: TimeInterval?
    public var lastEvaluated: TimeInterval?
    public var lastPowerSource: PowerSource?
    public var drainSamples: [DrainSample] = []

    public init() {}
}

public enum ArmOutcome: Equatable, Sendable {
    case holding
    /// Armed, but the schedule is closed. `opensAt` is nil when no window exists.
    case waitingForSchedule(opensAt: Date?)
    /// A rule fails right now; nothing was armed.
    case refused([TripInfo])
}

public struct ArmResult: Equatable, Sendable {
    public var state: EngineState
    public var outcome: ArmOutcome
    public var decision: Decision
}

/// One pure function decides everything: `evaluate(snapshot, config, state, now)`.
/// No I/O, no clock reads, no randomness.
public enum RuleEngine {

    // MARK: - Public API

    public static func evaluate(_ snapshot: Snapshot, config: Config, state: EngineState, now: Moment) -> Decision {
        step(snapshot, config: config.clamped(), state: state, now: now, arming: false)
    }

    /// Arms the switch. Runs the checks first: a rule that fails right now
    /// refuses the arm and leaves `state` untouched. A closed schedule arms
    /// into Waiting.
    public static func arm(_ snapshot: Snapshot, config: Config, state: EngineState, now: Moment,
                           duration: ArmDuration) -> ArmResult {
        let config = config.clamped()
        var s = state
        s.phase = .waiting
        s.heldSince = nil
        s.lastTrip = nil
        s.lidSince = nil
        s.idleSince = nil
        s.noProcessSince = nil
        s.noNetworkSince = nil
        s.lastPowerSource = snapshot.powerSource
        s.armDeadlineMonotonic = nil
        s.armDeadlineWall = nil
        if let seconds = duration.seconds {
            s.armDeadlineMonotonic = now.monotonic + seconds
        } else if duration == .untilScheduleEnd {
            s.armDeadlineWall = config.schedule.currentWindowEnd(at: now.wall, in: now.timeZone)
        }
        let decision = step(snapshot, config: config, state: s, now: now, arming: true)
        let blocking = decision.failing.filter { $0.rule != .schedule }
        if !blocking.isEmpty {
            var refused = decision
            refused.state = state
            refused.phase = state.phase
            refused.action = .none
            return ArmResult(state: state, outcome: .refused(blocking), decision: refused)
        }
        let outcome: ArmOutcome = decision.phase == .holding
            ? .holding : .waitingForSchedule(opensAt: decision.nextScheduleOpen)
        return ArmResult(state: decision.state, outcome: outcome, decision: decision)
    }

    /// The user switched off. Returns the new state and whether the helper must release.
    public static func disarm(_ state: EngineState) -> (state: EngineState, action: Action) {
        var s = state
        let wasHolding = s.phase == .holding
        s.phase = .off
        s.heldSince = nil
        s.armDeadlineMonotonic = nil
        s.armDeadlineWall = nil
        return (s, wasHolding ? .release : .none)
    }

    /// The user clicked the tripped icon.
    public static func acknowledge(_ state: EngineState) -> EngineState {
        var s = state
        if s.phase == .tripped { s.phase = .off }
        return s
    }

    // MARK: - Evaluation

    private struct SensorResult {
        var valid: Bool
        var active: Bool
    }

    private static func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    private static func sensor(_ value: Double?, tracker: inout SensorTracker, enabled: Bool, limit: Double,
                               sustain: Int, clearMargin: Double, rule: RuleID,
                               latched: inout Set<RuleID>, now: TimeInterval, instant: Bool) -> SensorResult {
        var valid = false
        if let v = value, v >= 0, v <= 130 {
            if tracker.lastValue == v {
                let stuck = now - (tracker.lastChange ?? now) >= Config.stuckReadingSeconds
                valid = !stuck
            } else {
                tracker.lastValue = v
                tracker.lastChange = now
                valid = true
            }
        }
        if valid { tracker.invalidSince = nil } else { tracker.invalidSince = tracker.invalidSince ?? now }

        guard enabled else {
            tracker.exceededSince = nil
            latched.remove(rule)
            return SensorResult(valid: valid, active: false)
        }
        guard valid, let v = value else {
            tracker.exceededSince = nil
            return SensorResult(valid: valid, active: latched.contains(rule))
        }
        if latched.contains(rule) {
            if v <= limit - clearMargin {
                latched.remove(rule)
                tracker.exceededSince = nil
                return SensorResult(valid: true, active: false)
            }
            return SensorResult(valid: true, active: true)
        }
        if v >= limit {
            let since = tracker.exceededSince ?? now
            tracker.exceededSince = since
            if instant || now - since >= Double(sustain) {
                latched.insert(rule)
                return SensorResult(valid: true, active: true)
            }
        } else {
            tracker.exceededSince = nil
        }
        return SensorResult(valid: true, active: false)
    }

    private static func step(_ snap: Snapshot, config: Config, state: EngineState, now: Moment,
                             arming: Bool) -> Decision {
        var s = state
        let prev = s.phase
        let m = now.monotonic

        // Sleep gap or clock trouble: sustain counters start over.
        let interval = Double(prev == .holding ? config.holdingIntervalSeconds : config.offIntervalSeconds)
        var gap = false
        if let last = s.lastEvaluated { gap = m < last || m - last > 2 * interval }
        if gap {
            for path in [\EngineState.cpu, \EngineState.gpu, \EngineState.batteryTemp] {
                s[keyPath: path].exceededSince = nil
                s[keyPath: path].invalidSince = nil
                s[keyPath: path].lastChange = m
            }
        }
        let woke = snap.didWake || gap
        s.lastEvaluated = m

        let thermalOnly = config.sensorPreference == .thermalStateOnly
        var failures: [TripInfo] = []

        // Temperature rules.
        func sustainText(_ n: Int) -> String { n > 0 ? " for \(n) s" : "" }
        let cpu = sensor(thermalOnly ? nil : snap.cpuTemperature, tracker: &s.cpu, enabled: config.cpuEnabled && !thermalOnly,
                         limit: config.cpuLimit, sustain: config.cpuSustainSeconds, clearMargin: config.cpuClearMargin,
                         rule: .cpuTemperature, latched: &s.latched, now: m, instant: arming)
        if cpu.active {
            let v = snap.cpuTemperature
            failures.append(TripInfo(rule: .cpuTemperature, value: v, limit: config.cpuLimit,
                message: "CPU temperature \(v.map(fmt) ?? "unknown") °C is at or above \(fmt(config.cpuLimit)) °C\(sustainText(config.cpuSustainSeconds))",
                shortReason: RuleID.cpuTemperature.shortReason(value: v, config: config)))
        }
        let gpu = sensor(thermalOnly ? nil : snap.gpuTemperature, tracker: &s.gpu, enabled: config.gpuEnabled && !thermalOnly,
                         limit: config.gpuLimit, sustain: config.gpuSustainSeconds, clearMargin: config.gpuClearMargin,
                         rule: .gpuTemperature, latched: &s.latched, now: m, instant: arming)
        if gpu.active {
            let v = snap.gpuTemperature
            failures.append(TripInfo(rule: .gpuTemperature, value: v, limit: config.gpuLimit,
                message: "GPU temperature \(v.map(fmt) ?? "unknown") °C is at or above \(fmt(config.gpuLimit)) °C\(sustainText(config.gpuSustainSeconds))",
                shortReason: RuleID.gpuTemperature.shortReason(value: v, config: config)))
        }
        let bat = sensor(thermalOnly ? nil : snap.batteryTemperature, tracker: &s.batteryTemp, enabled: config.batteryTempEnabled && !thermalOnly,
                         limit: config.batteryTempLimit, sustain: config.batteryTempSustainSeconds, clearMargin: config.batteryTempClearMargin,
                         rule: .batteryTemperature, latched: &s.latched, now: m, instant: arming)
        if bat.active {
            let v = snap.batteryTemperature
            failures.append(TripInfo(rule: .batteryTemperature, value: v, limit: config.batteryTempLimit,
                message: "Battery temperature \(v.map(fmt) ?? "unknown") °C is at or above \(fmt(config.batteryTempLimit)) °C\(sustainText(config.batteryTempSustainSeconds))",
                shortReason: RuleID.batteryTemperature.shortReason(value: v, config: config)))
        }

        // Thermal pressure: no sustain, clears as soon as the level drops below the limit.
        if config.thermalEnabled && snap.thermal >= config.thermalLimit {
            failures.append(TripInfo(rule: .thermalPressure, value: Double(snap.thermal.rank), limit: Double(config.thermalLimit.rank),
                message: "Thermal state is \(snap.thermal.rawValue), limit is \(config.thermalLimit.rawValue)",
                shortReason: RuleID.thermalPressure.shortReason(value: nil, config: config)))
        }

        // Battery floor with hysteresis. An unreadable level fails closed.
        if config.floorEnabled {
            if s.latched.contains(.batteryFloor) {
                if snap.isCharging || (snap.batteryPercent ?? 0) >= config.floorPercent + 10 {
                    s.latched.remove(.batteryFloor)
                }
            } else if !snap.isCharging, (snap.batteryPercent ?? -1) < config.floorPercent {
                s.latched.insert(.batteryFloor)
            }
        } else {
            s.latched.remove(.batteryFloor)
        }
        if s.latched.contains(.batteryFloor) {
            let p = snap.batteryPercent
            failures.append(TripInfo(rule: .batteryFloor, value: p.map(Double.init), limit: Double(config.floorPercent),
                message: p.map { "Battery \($0)% is below \(config.floorPercent)%" } ?? "Battery level is unreadable",
                shortReason: RuleID.batteryFloor.shortReason(value: p.map(Double.init), config: config)))
        }

        // Sensor failure: CPU and battery temperature drive it, the GPU never does.
        if !thermalOnly {
            let since = [s.cpu.invalidSince, s.batteryTemp.invalidSince].compactMap { $0 }.min()
            if let since, m - since >= Double(config.sensorFailureSeconds) {
                failures.append(TripInfo(rule: .sensorFailure, value: nil, limit: Double(config.sensorFailureSeconds),
                    message: "No valid temperature reading for \(config.sensorFailureSeconds) s",
                    shortReason: RuleID.sensorFailure.shortReason(value: nil, config: config)))
            }
        }
        _ = (cpu.valid, gpu.valid, bat.valid)

        // Hard cap.
        if config.capEnabled, let held = s.heldSince, m - held >= Double(config.capHours) * 3600 {
            failures.append(TripInfo(rule: .hardCap, value: (m - held) / 3600, limit: Double(config.capHours),
                message: "Held for \(config.capHours) h, the time cap",
                shortReason: RuleID.hardCap.shortReason(value: nil, config: config)))
        }

        // Lid closed on battery.
        if config.lidEnabled, snap.lidClosed, snap.powerSource == .battery {
            s.lidSince = s.lidSince ?? m
        } else {
            s.lidSince = nil
        }
        if let since = s.lidSince, m - since >= Double(config.lidMinutes) * 60 {
            failures.append(TripInfo(rule: .lidOnBattery, value: (m - since) / 60, limit: Double(config.lidMinutes),
                message: "Lid closed on battery for \(config.lidMinutes) min",
                shortReason: RuleID.lidOnBattery.shortReason(value: nil, config: config)))
        }

        // Network.
        if config.networkEnabled, !snap.networkUsable {
            s.noNetworkSince = s.noNetworkSince ?? m
        } else {
            s.noNetworkSince = nil
        }
        if let since = s.noNetworkSince, m - since >= Double(config.networkMinutes) * 60 {
            failures.append(TripInfo(rule: .noNetwork, value: (m - since) / 60, limit: Double(config.networkMinutes),
                message: "No network route for \(config.networkMinutes) min",
                shortReason: RuleID.noNetwork.shortReason(value: nil, config: config)))
        }

        // Idle: lid closed only. Starts below the limit, resets above limit plus 10 points.
        if config.idleEnabled, snap.lidClosed, let load = snap.cpuLoadPercent {
            if load < Double(config.idleCpuPercent) {
                s.idleSince = s.idleSince ?? m
            } else if load >= Double(config.idleCpuPercent + 10) {
                s.idleSince = nil
            }
        } else {
            s.idleSince = nil
        }
        if let since = s.idleSince, m - since >= Double(config.idleMinutes) * 60 {
            failures.append(TripInfo(rule: .idle, value: snap.cpuLoadPercent, limit: Double(config.idleCpuPercent),
                message: "CPU below \(config.idleCpuPercent)% for \(config.idleMinutes) min with the lid closed",
                shortReason: RuleID.idle.shortReason(value: nil, config: config)))
        }

        // Watched process. An unknown answer counts as not running.
        if config.watchedEnabled, snap.watchedProcessRunning != true {
            s.noProcessSince = s.noProcessSince ?? m
        } else {
            s.noProcessSince = nil
        }
        if let since = s.noProcessSince, m - since >= Double(config.watchedMinutes) * 60 {
            failures.append(TripInfo(rule: .watchedProcess, value: (m - since) / 60, limit: Double(config.watchedMinutes),
                message: "None of \(config.watchedNames.joined(separator: ", ")) ran for \(config.watchedMinutes) min",
                shortReason: RuleID.watchedProcess.shortReason(value: nil, config: config)))
        }

        failures.sort { $0.rule.priority < $1.rule.priority }

        // Schedule is a gate. It only counts as a failure while holding.
        let scheduleOpen = config.schedule.isOpen(at: now.wall, in: now.timeZone)
        let scheduleTrip = TripInfo(rule: .schedule, value: nil, limit: nil,
            message: "Outside the allowed hours", shortReason: RuleID.schedule.shortReason(value: nil, config: config))

        // Phase transitions.
        var action: Action = .none
        var trip: TripInfo?
        var timerEnded = false

        func deadlinePassed() -> Bool {
            if let d = s.armDeadlineMonotonic, m >= d { return true }
            if let d = s.armDeadlineWall, now.wall >= d { return true }
            return false
        }

        switch s.phase {
        case .off:
            break
        case .waiting, .holding:
            if deadlinePassed() {
                s.phase = .off
                s.heldSince = nil
                s.armDeadlineMonotonic = nil
                s.armDeadlineWall = nil
                timerEnded = true
                if prev == .holding { action = .release }
            } else if s.phase == .holding {
                var all = failures
                if !scheduleOpen { all.append(scheduleTrip); all.sort { $0.rule.priority < $1.rule.priority } }
                if let primary = all.first {
                    s.phase = .tripped
                    s.lastTrip = primary
                    s.heldSince = nil
                    trip = primary
                    action = .release
                }
            } else if scheduleOpen && failures.isEmpty {
                s.phase = .holding
                s.heldSince = m
                action = .hold
            }
        case .tripped:
            if woke, config.afterTrip == .rearmOnWake, let last = s.lastTrip,
               last.rule != .hardCap, last.rule != .sensorFailure, failures.isEmpty {
                s.lastTrip = nil
                if scheduleOpen {
                    s.phase = .holding
                    s.heldSince = m
                    action = .hold
                } else {
                    s.phase = .waiting
                }
            }
        }

        // Unplug alert: once per AC to battery change, only while armed or holding.
        var alerts: [Alert] = []
        if config.alertOnUnplug, s.lastPowerSource == .ac, snap.powerSource == .battery,
           prev == .waiting || prev == .holding {
            alerts.append(.unpluggedWhileHolding)
        }
        s.lastPowerSource = snap.powerSource

        // Drain samples for the forecast.
        if snap.powerSource == .battery, !snap.isCharging, let p = snap.batteryPercent {
            if s.drainSamples.last?.monotonic != m { s.drainSamples.append(DrainSample(monotonic: m, percent: p)) }
            s.drainSamples.removeAll { m - $0.monotonic > Forecast.window }
        } else {
            s.drainSamples = []
        }

        let margins = makeMargins(snap, config: config, state: s, now: now, scheduleOpen: scheduleOpen)
        var shownFailing = failures
        if s.phase == .holding || prev == .holding, !scheduleOpen, config.schedule.enabled { shownFailing.append(scheduleTrip) }
        shownFailing.sort { $0.rule.priority < $1.rule.priority }

        return Decision(
            state: s, phase: s.phase, action: action, failing: shownFailing, trip: trip, alerts: alerts,
            timerEnded: timerEnded, margins: margins, nextToTrip: Forecast.nextToTrip(margins),
            warnings: margins.filter { $0.fraction <= Forecast.warningFraction }.map(\.rule),
            timeLeft: Forecast.timeLeft(margins), scheduleOpen: scheduleOpen,
            nextScheduleOpen: config.schedule.nextOpen(from: now.wall, in: now.timeZone))
    }

    // MARK: - Margins

    private static func makeMargins(_ snap: Snapshot, config: Config, state s: EngineState, now: Moment,
                                    scheduleOpen: Bool) -> [RuleMargin] {
        let m = now.monotonic
        var out: [RuleMargin] = []

        func temp(_ rule: RuleID, _ name: String, _ v: Double?, _ limit: Double, enabled: Bool) {
            guard enabled, let v else { return }
            let latched = s.latched.contains(rule)
            out.append(RuleMargin(rule: rule, fraction: latched ? 0 : (limit - v) / limit, seconds: nil,
                                  detail: "\(name) \(fmt(v))° of \(fmt(limit))°"))
        }
        let thermalOnly = config.sensorPreference == .thermalStateOnly
        temp(.cpuTemperature, "CPU", snap.cpuTemperature, config.cpuLimit, enabled: config.cpuEnabled && !thermalOnly)
        temp(.gpuTemperature, "GPU", snap.gpuTemperature, config.gpuLimit, enabled: config.gpuEnabled && !thermalOnly)
        temp(.batteryTemperature, "Battery", snap.batteryTemperature, config.batteryTempLimit,
             enabled: config.batteryTempEnabled && !thermalOnly)

        if config.thermalEnabled {
            let lim = Double(config.thermalLimit.rank)
            out.append(RuleMargin(rule: .thermalPressure, fraction: (lim - Double(snap.thermal.rank)) / lim, seconds: nil,
                                  detail: "Thermal \(snap.thermal.rawValue), limit \(config.thermalLimit.rawValue)"))
        }

        if config.floorEnabled, let p = snap.batteryPercent {
            var seconds: TimeInterval?
            var fraction = Double(p - config.floorPercent) / Double(max(1, 100 - config.floorPercent))
            if snap.isCharging { fraction = 1 }
            else { seconds = Forecast.timeToFloor(percent: p, floor: config.floorPercent,
                                                  slope: Forecast.drainSlope(samples: s.drainSamples, now: m)) }
            out.append(RuleMargin(rule: .batteryFloor, fraction: fraction, seconds: seconds,
                                  detail: "Battery \(p)%, floor \(config.floorPercent)%"))
        }

        func timed(_ rule: RuleID, _ name: String, enabled: Bool, since: TimeInterval?, total: TimeInterval) {
            guard enabled else { return }
            guard let since else {
                out.append(RuleMargin(rule: rule, fraction: 1, seconds: nil, detail: name))
                return
            }
            let remaining = max(0, total - (m - since))
            out.append(RuleMargin(rule: rule, fraction: remaining / total, seconds: remaining, detail: name))
        }
        timed(.lidOnBattery, "Lid on battery", enabled: config.lidEnabled, since: s.lidSince, total: Double(config.lidMinutes) * 60)
        timed(.idle, "Idle", enabled: config.idleEnabled, since: s.idleSince, total: Double(config.idleMinutes) * 60)
        timed(.watchedProcess, "No watched process", enabled: config.watchedEnabled, since: s.noProcessSince,
              total: Double(config.watchedMinutes) * 60)
        timed(.noNetwork, "No network", enabled: config.networkEnabled, since: s.noNetworkSince,
              total: Double(config.networkMinutes) * 60)
        timed(.hardCap, "Time cap", enabled: config.capEnabled, since: s.heldSince, total: Double(config.capHours) * 3600)

        if config.schedule.enabled, scheduleOpen,
           let end = config.schedule.currentWindowEnd(at: now.wall, in: now.timeZone) {
            let remaining = max(0, end.timeIntervalSince(now.wall))
            out.append(RuleMargin(rule: .schedule, fraction: min(1, remaining / 3600), seconds: remaining,
                                  detail: "Schedule ends"))
        }

        if let since = [s.cpu.invalidSince, s.batteryTemp.invalidSince].compactMap({ $0 }).min() {
            let total = Double(config.sensorFailureSeconds)
            let remaining = max(0, total - (m - since))
            out.append(RuleMargin(rule: .sensorFailure, fraction: remaining / total, seconds: remaining,
                                  detail: "Temperature sensors unreadable"))
        }
        return out
    }
}
