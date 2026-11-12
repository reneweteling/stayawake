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
    /// Rolling windows and source hold of the CPU and GPU readings.
    public var cpuSignal = SignalTracker()
    public var gpuSignal = SignalTracker()
    /// Battery readings of the last 5 minutes while the heating-up rule runs.
    public var batteryHistory: [TimedValue] = []
    /// Since when the thermal state is at or above the limit.
    public var thermalSince: TimeInterval?
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
        /// The value the limit was compared with: the rolling mean for CPU and GPU.
        var compared: Double?
        var samples: Int
    }

    private static func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    /// One temperature rule. `value` is the reading after the source hold.
    /// Validity and stuck detection look at that reading; the limit and the
    /// clears-at level are compared with the rolling mean over `smooth`
    /// seconds when it is given, with the reading itself otherwise.
    private static func sensor(_ value: Double?, smooth: TimeInterval?, samples: inout [TimedValue], tracker: inout SensorTracker,
                               enabled: Bool, limit: Double, sustain: Int, clearMargin: Double, rule: RuleID,
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

        var compared: Double?
        var count = 0
        if valid, let v = value {
            if let window = smooth {
                compared = Smoothing.add(v, samples: &samples, now: now, window: window)
                count = samples.count
            } else {
                compared = v
                count = 1
            }
        }

        guard enabled else {
            tracker.exceededSince = nil
            latched.remove(rule)
            return SensorResult(valid: valid, active: false, compared: compared, samples: count)
        }
        guard let v = compared else {
            tracker.exceededSince = nil
            return SensorResult(valid: valid, active: latched.contains(rule), compared: nil, samples: 0)
        }
        if latched.contains(rule) {
            if v <= limit - clearMargin {
                latched.remove(rule)
                tracker.exceededSince = nil
                return SensorResult(valid: true, active: false, compared: v, samples: count)
            }
            return SensorResult(valid: true, active: true, compared: v, samples: count)
        }
        if v >= limit {
            let since = tracker.exceededSince ?? now
            tracker.exceededSince = since
            if instant || now - since >= Double(sustain) {
                latched.insert(rule)
                return SensorResult(valid: true, active: true, compared: v, samples: count)
            }
        } else {
            tracker.exceededSince = nil
        }
        return SensorResult(valid: true, active: false, compared: v, samples: count)
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
            s.cpuSignal = SignalTracker()
            s.gpuSignal = SignalTracker()
            s.batteryHistory = []
            s.thermalSince = nil
        }
        let woke = snap.didWake || gap
        s.lastEvaluated = m

        let thermalOnly = config.sensorPreference == .thermalStateOnly
        var failures: [TripInfo] = []

        // Temperature rules. CPU and GPU: source hold, then the rolling mean
        // (60 s by default) against the limit. Battery: the hottest battery
        // sensor as it is.
        let window = TimeInterval(config.smoothingSeconds)
        let avgText = config.smoothingSeconds > 0 ? " (\(config.smoothingSeconds) s average)" : ""
        func sustainText(_ n: Int) -> String { n > 0 ? " for \(n) s" : "" }
        let cpuIn = thermalOnly ? (value: nil, source: TemperatureSource.none)
            : Smoothing.hold(snap.cpuTemperature, source: snap.cpuSource, tracker: &s.cpuSignal, now: m)
        let cpu = sensor(cpuIn.value, smooth: window, samples: &s.cpuSignal.samples, tracker: &s.cpu,
                         enabled: config.cpuEnabled && !thermalOnly,
                         limit: config.cpuLimit, sustain: config.cpuSustainSeconds, clearMargin: config.cpuClearMargin,
                         rule: .cpuTemperature, latched: &s.latched, now: m, instant: arming)
        if cpu.active {
            let v = cpu.compared
            failures.append(TripInfo(rule: .cpuTemperature, value: v, limit: config.cpuLimit,
                message: "CPU temperature \(v.map(fmt) ?? "unknown") °C\(avgText) is at or above \(fmt(config.cpuLimit)) °C\(sustainText(config.cpuSustainSeconds))",
                shortReason: RuleID.cpuTemperature.shortReason(value: v, config: config)))
        }
        let gpuIn = thermalOnly ? (value: nil, source: TemperatureSource.none)
            : Smoothing.hold(snap.gpuTemperature, source: snap.gpuSource, tracker: &s.gpuSignal, now: m)
        let gpu = sensor(gpuIn.value, smooth: window, samples: &s.gpuSignal.samples, tracker: &s.gpu,
                         enabled: config.gpuEnabled && !thermalOnly,
                         limit: config.gpuLimit, sustain: config.gpuSustainSeconds, clearMargin: config.gpuClearMargin,
                         rule: .gpuTemperature, latched: &s.latched, now: m, instant: arming)
        if gpu.active {
            let v = gpu.compared
            failures.append(TripInfo(rule: .gpuTemperature, value: v, limit: config.gpuLimit,
                message: "GPU temperature \(v.map(fmt) ?? "unknown") °C\(avgText) is at or above \(fmt(config.gpuLimit)) °C\(sustainText(config.gpuSustainSeconds))",
                shortReason: RuleID.gpuTemperature.shortReason(value: v, config: config)))
        }
        var unsmoothed: [TimedValue] = []
        let bat = sensor(thermalOnly ? nil : snap.batteryTemperature, smooth: nil, samples: &unsmoothed, tracker: &s.batteryTemp, enabled: config.batteryTempEnabled && !thermalOnly,
                         limit: config.batteryTempLimit, sustain: config.batteryTempSustainSeconds, clearMargin: config.batteryTempClearMargin,
                         rule: .batteryTemperature, latched: &s.latched, now: m, instant: arming)
        if bat.active {
            let v = snap.batteryTemperature
            failures.append(TripInfo(rule: .batteryTemperature, value: v, limit: config.batteryTempLimit,
                message: "Battery temperature \(v.map(fmt) ?? "unknown") °C is at or above \(fmt(config.batteryTempLimit)) °C\(sustainText(config.batteryTempSustainSeconds))",
                shortReason: RuleID.batteryTemperature.shortReason(value: v, config: config)))
        }

        // Battery heating up: lid closed on battery only. Trips when the
        // battery is more than the set rise above its coolest reading of the
        // last 5 minutes. No sustain: the window is the wait.
        var batteryRise: Double?
        if config.batteryHeatingEnabled, !thermalOnly, snap.lidClosed, snap.powerSource == .battery,
           bat.valid, let b = snap.batteryTemperature {
            let rise = Smoothing.rise(b, history: &s.batteryHistory, now: m, window: Config.batteryHeatingWindowSeconds)
            batteryRise = rise
            if rise > config.batteryHeatingRise {
                failures.append(TripInfo(rule: .batteryHeating, value: rise, limit: config.batteryHeatingRise,
                    message: "Battery temperature rose \(String(format: "%.1f", rise)) °C in \(Int(Config.batteryHeatingWindowSeconds / 60)) min with the lid closed on battery, limit \(fmt(config.batteryHeatingRise)) °C",
                    shortReason: RuleID.batteryHeating.shortReason(value: rise, config: config)))
            }
        } else {
            s.batteryHistory = []
        }

        // Thermal pressure: critical trips at once. A lower level at or above
        // the limit trips after it lasted `thermalSustainSeconds`. Clears as
        // soon as the level drops below the limit.
        if config.thermalEnabled && snap.thermal >= config.thermalLimit {
            let since = s.thermalSince ?? m
            s.thermalSince = since
            if snap.thermal == .critical || arming || m - since >= Double(config.thermalSustainSeconds) {
                let wait = snap.thermal == .critical ? "" : sustainText(config.thermalSustainSeconds)
                failures.append(TripInfo(rule: .thermalPressure, value: Double(snap.thermal.rank), limit: Double(config.thermalLimit.rank),
                    message: "Thermal state is \(snap.thermal.rawValue)\(wait), limit is \(config.thermalLimit.rawValue)",
                    shortReason: RuleID.thermalPressure.shortReason(value: nil, config: config)))
            }
        } else {
            s.thermalSince = nil
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

        let signals = Signals(
            cpu: SignalReading(instant: thermalOnly ? nil : snap.cpuTemperature, smoothed: cpu.compared,
                               source: cpuIn.source, samples: cpu.samples),
            gpu: SignalReading(instant: thermalOnly ? nil : snap.gpuTemperature, smoothed: gpu.compared,
                               source: gpuIn.source, samples: gpu.samples),
            battery: SignalReading(instant: thermalOnly ? nil : snap.batteryTemperature, smoothed: bat.compared,
                                   source: bat.compared == nil ? .none : .smc, samples: bat.samples),
            batteryRise: batteryRise)
        let margins = makeMargins(snap, signals: signals, config: config, state: s, now: now, scheduleOpen: scheduleOpen)
        var shownFailing = failures
        if s.phase == .holding || prev == .holding, !scheduleOpen, config.schedule.enabled { shownFailing.append(scheduleTrip) }
        shownFailing.sort { $0.rule.priority < $1.rule.priority }

        return Decision(
            state: s, phase: s.phase, action: action, failing: shownFailing, trip: trip, alerts: alerts,
            timerEnded: timerEnded, margins: margins, nextToTrip: Forecast.nextToTrip(margins),
            warnings: margins.filter { $0.fraction <= Forecast.warningFraction }.map(\.rule),
            timeLeft: Forecast.timeLeft(margins), scheduleOpen: scheduleOpen,
            nextScheduleOpen: config.schedule.nextOpen(from: now.wall, in: now.timeZone), signals: signals)
    }

    // MARK: - Margins

    private static func makeMargins(_ snap: Snapshot, signals: Signals, config: Config, state s: EngineState, now: Moment,
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
        temp(.cpuTemperature, "CPU", signals.cpu.smoothed, config.cpuLimit, enabled: config.cpuEnabled && !thermalOnly)
        temp(.gpuTemperature, "GPU", signals.gpu.smoothed, config.gpuLimit, enabled: config.gpuEnabled && !thermalOnly)
        temp(.batteryTemperature, "Battery", signals.battery.smoothed, config.batteryTempLimit,
             enabled: config.batteryTempEnabled && !thermalOnly)

        if let rise = signals.batteryRise {
            let lim = config.batteryHeatingRise
            out.append(RuleMargin(rule: .batteryHeating, fraction: (lim - rise) / lim, seconds: nil,
                                  detail: "Battery up \(String(format: "%.1f", max(0, rise)))° in 5 min of \(fmt(lim))°"))
        }

        if config.thermalEnabled {
            let lim = Double(config.thermalLimit.rank)
            var seconds: TimeInterval?
            var fraction = (lim - Double(snap.thermal.rank)) / lim
            if let since = s.thermalSince, snap.thermal < .critical, config.thermalSustainSeconds > 0 {
                let total = Double(config.thermalSustainSeconds)
                let remaining = max(0, total - (m - since))
                seconds = remaining
                fraction = remaining / total * Forecast.warningFraction
            }
            out.append(RuleMargin(rule: .thermalPressure, fraction: fraction, seconds: seconds,
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
