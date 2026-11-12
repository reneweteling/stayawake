import Foundation

/// Feeds a scripted sequence of snapshots through the engine with a fake
/// clock. Used by `StayAwake --simulate scenario.json` and by tests.
///
/// Scenario format (all keys optional except steps):
///
///     {
///       "start": "2026-11-12T09:00:00+01:00",
///       "timeZone": "Europe/Amsterdam",
///       "config": { "cpuLimit": 70 },
///       "snapshot": { "batteryPercent": 80 },
///       "steps": [
///         { "at": 0, "command": "arm", "arm": "untilTrip" },
///         { "at": 15, "snapshot": { "cpuTemperature": 85 } },
///         { "at": 45, "snapshot": { "powerSource": "ac" }, "missing": ["gpuTemperature"] }
///       ]
///     }
///
/// Each step's snapshot patch is applied on top of the previous snapshot.
/// `missing` sets sensor readings to nil. `at` is seconds since the start.
public enum Simulator {

    public struct Step {
        public var at: TimeInterval
        public var command: String?
        public var arm: ArmDuration
        public var patch: [String: Any]
        public var missing: [String]

    }

    public struct Scenario {
        public var start: Date
        public var timeZone: TimeZone
        public var config: Config
        public var base: Snapshot
        public var steps: [Step]
    }

    public struct StepResult: Equatable, Sendable {
        public var at: TimeInterval
        public var command: String
        public var decision: Decision
        public var armOutcome: ArmOutcome?
        public var line: String
    }

    public enum SimulatorError: Error, CustomStringConvertible {
        case invalid(String)
        public var description: String {
            if case .invalid(let m) = self { return m }
            return "invalid scenario"
        }
    }

    public static func parse(_ data: Data) throws -> Scenario {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SimulatorError.invalid("scenario must be a JSON object")
        }
        var start = Date(timeIntervalSince1970: 1_794_000_000)
        if let text = root["start"] as? String {
            let f = ISO8601DateFormatter()
            guard let d = f.date(from: text) else { throw SimulatorError.invalid("start is not an ISO 8601 date: \(text)") }
            start = d
        }
        var tz = TimeZone.current
        if let id = root["timeZone"] as? String {
            guard let z = TimeZone(identifier: id) else { throw SimulatorError.invalid("unknown time zone \(id)") }
            tz = z
        }
        var config = Config()
        if let c = root["config"] {
            config = try Config.decodeLenient(from: JSONSerialization.data(withJSONObject: c))
        }
        var base = Snapshot()
        if let p = root["snapshot"] as? [String: Any] { base = try apply(p, missing: [], to: base) }
        guard let rawSteps = root["steps"] as? [[String: Any]] else { throw SimulatorError.invalid("steps is required") }
        let steps = try rawSteps.map { raw -> Step in
            guard let at = (raw["at"] as? NSNumber)?.doubleValue else { throw SimulatorError.invalid("every step needs a numeric \"at\"") }
            let arm = ArmDuration(rawValue: raw["arm"] as? String ?? "") ?? .untilTrip
            return Step(at: at, command: raw["command"] as? String, arm: arm,
                        patch: raw["snapshot"] as? [String: Any] ?? [:], missing: raw["missing"] as? [String] ?? [])
        }
        return Scenario(start: start, timeZone: tz, config: config, base: base, steps: steps)
    }

    static func apply(_ patch: [String: Any], missing: [String], to snap: Snapshot) throws -> Snapshot {
        var dict = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snap)) as! [String: Any]
        for (k, v) in patch { dict[k] = v }
        for k in missing { dict.removeValue(forKey: k) }
        let next = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: dict))
        return next
    }

    public static func run(_ scenario: Scenario) throws -> [StepResult] {
        var state = EngineState()
        var snap = scenario.base
        var results: [StepResult] = []
        for step in scenario.steps.sorted(by: { $0.at < $1.at }) {
            snap = try apply(step.patch, missing: step.missing, to: snap)
            let now = Moment(monotonic: step.at, wall: scenario.start.addingTimeInterval(step.at), timeZone: scenario.timeZone)
            var outcome: ArmOutcome?
            let decision: Decision
            let name = step.command ?? "evaluate"
            switch name {
            case "arm":
                let r = RuleEngine.arm(snap, config: scenario.config, state: state, now: now, duration: step.arm)
                state = r.state
                outcome = r.outcome
                decision = r.decision
            case "disarm":
                let r = RuleEngine.disarm(state)
                state = r.state
                var d = RuleEngine.evaluate(snap, config: scenario.config, state: state, now: now)
                state = d.state
                d.action = r.action
                decision = d
            case "ack":
                state = RuleEngine.acknowledge(state)
                decision = RuleEngine.evaluate(snap, config: scenario.config, state: state, now: now)
                state = decision.state
            case "evaluate":
                decision = RuleEngine.evaluate(snap, config: scenario.config, state: state, now: now)
                state = decision.state
            default:
                throw SimulatorError.invalid("unknown command \(name)")
            }
            results.append(StepResult(at: step.at, command: name, decision: decision, armOutcome: outcome,
                                      line: describe(step.at, name, decision, outcome)))
        }
        return results
    }

    static func describe(_ at: TimeInterval, _ command: String, _ d: Decision, _ outcome: ArmOutcome?) -> String {
        var parts = ["t=+\(Int(at))s", command, "phase=\(d.phase.rawValue)", "action=\(d.action.rawValue)"]
        if case .refused(let r)? = outcome { parts.append("refused=[\(r.map(\.shortReason).joined(separator: ", "))]") }
        if let t = d.trip { parts.append("TRIP \(t.shortReason): \(t.message)") }
        else if !d.failing.isEmpty { parts.append("failing=[\(d.failing.map(\.shortReason).joined(separator: ", "))]") }
        if !d.alerts.isEmpty { parts.append("alerts=[\(d.alerts.map(\.rawValue).joined(separator: ", "))]") }
        if d.timerEnded { parts.append("timer-ended") }
        if let left = d.timeLeft { parts.append("left=\(Int(left))s") }
        if let next = d.nextToTrip.first { parts.append("next=\(next.rule.rawValue)") }
        return parts.joined(separator: " ")
    }
}
