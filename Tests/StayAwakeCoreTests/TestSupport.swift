import Foundation
import XCTest
@testable import StayAwakeCore

let amsterdam = TimeZone(identifier: "Europe/Amsterdam")!

func iso(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text)!
}

/// A Monday at 10:00 in Amsterdam (09:00 UTC).
let mondayMorning = iso("2026-11-09T09:00:00Z")

/// Runs the engine like the app would: keeps the state, advances both clocks.
struct Rig {
    var config: Config
    var state = EngineState()
    var snap = Snapshot()
    var now: Moment
    var last: Decision?

    init(schedule: Schedule = .off, start: Date = mondayMorning, tweak: (inout Config) -> Void = { _ in }) {
        var c = Config()
        c.schedule = schedule
        tweak(&c)
        config = c
        now = Moment(monotonic: 1000, wall: start, timeZone: amsterdam)
    }

    @discardableResult
    mutating func arm(_ duration: ArmDuration = .untilTrip) -> ArmResult {
        let r = RuleEngine.arm(snap, config: config, state: state, now: now, duration: duration)
        state = r.state
        last = r.decision
        return r
    }

    @discardableResult
    mutating func eval() -> Decision {
        let d = RuleEngine.evaluate(snap, config: config, state: state, now: now)
        state = d.state
        last = d
        snap.didWake = false
        return d
    }

    /// Evaluates every `step` seconds for `seconds`. With `jitter`, temperature
    /// readings wobble a little so they never count as stuck.
    @discardableResult
    mutating func advance(_ seconds: Double, step: Double = 15, jitter: Bool = true) -> [Decision] {
        var out: [Decision] = []
        var elapsed = 0.0
        let base = snap
        var n = 0
        while elapsed < seconds {
            now = now.advanced(by: step)
            elapsed += step
            n += 1
            if jitter {
                let w = Double(n % 2) * 0.01
                snap.cpuTemperature = base.cpuTemperature.map { $0 + w }
                snap.gpuTemperature = base.gpuTemperature.map { $0 + w }
                snap.batteryTemperature = base.batteryTemperature.map { $0 + w }
            }
            out.append(eval())
        }
        return out
    }

    /// Jumps the clocks without evaluating, like a sleep.
    mutating func sleep(_ seconds: Double) { now = now.advanced(by: seconds) }
}

extension Decision {
    var rules: [RuleID] { failing.map(\.rule) }
}

func weekdays(_ windows: [TimeWindow], on days: [Int]) -> Schedule {
    Schedule(enabled: true, days: (0..<7).map { days.contains($0) ? windows : [] })
}
