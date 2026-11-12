import Foundation

public struct DrainSample: Codable, Equatable, Sendable {
    public var monotonic: TimeInterval
    public var percent: Int

    public init(monotonic: TimeInterval, percent: Int) {
        self.monotonic = monotonic
        self.percent = percent
    }
}

public enum Forecast {
    /// Samples older than this are ignored for the drain slope.
    public static let window: TimeInterval = 600
    /// Less data than this gives no estimate.
    public static let minimumSpan: TimeInterval = 120
    public static let minimumSamples = 2
    /// A rule is in the warning band when it is within this share of its limit.
    public static let warningFraction = 0.10

    /// Battery percent per second over the last 10 minutes, by least squares.
    /// Negative means draining. Nil when there is too little data.
    public static func drainSlope(samples: [DrainSample], now: TimeInterval) -> Double? {
        let recent = samples.filter { now - $0.monotonic <= window && $0.monotonic <= now }
        guard recent.count >= minimumSamples,
              let first = recent.map(\.monotonic).min(), let last = recent.map(\.monotonic).max(),
              last - first >= minimumSpan else { return nil }
        let n = Double(recent.count)
        let xs = recent.map { $0.monotonic - first }
        let ys = recent.map { Double($0.percent) }
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let sxx = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        guard sxx > 0 else { return nil }
        let sxy = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        return sxy / sxx
    }

    /// Seconds until the battery reaches `floor` at `slope`. Nil when the
    /// battery is not draining. Zero when already at or below the floor.
    public static func timeToFloor(percent: Int, floor: Int, slope: Double?) -> TimeInterval? {
        guard let slope, slope < 0 else { return nil }
        if percent <= floor { return 0 }
        return Double(percent - floor) / -slope
    }

    /// Margins ordered by how soon each rule trips. Rules in the warning band
    /// come first (closest first), then rules with a time estimate (soonest
    /// first), then the remaining sensor rules by distance to the limit.
    public static func rank(_ margins: [RuleMargin]) -> [RuleMargin] {
        func group(_ m: RuleMargin) -> Int {
            if m.fraction <= warningFraction { return 0 }
            return m.seconds != nil ? 1 : 2
        }
        return margins.sorted { a, b in
            let ga = group(a), gb = group(b)
            if ga != gb { return ga < gb }
            switch ga {
            case 1:
                if a.seconds! != b.seconds! { return a.seconds! < b.seconds! }
            default:
                if a.fraction != b.fraction { return a.fraction < b.fraction }
            }
            return a.rule.priority < b.rule.priority
        }
    }

    public static func nextToTrip(_ margins: [RuleMargin], count: Int = 3) -> [RuleMargin] {
        Array(rank(margins).prefix(count))
    }

    /// Time left is the smallest estimate of the rules that have one: hard
    /// cap, schedule end, lid-on-battery limit, time to the battery floor.
    public static func timeLeft(_ margins: [RuleMargin]) -> TimeInterval? {
        let candidates: Set<RuleID> = [.hardCap, .schedule, .lidOnBattery, .batteryFloor]
        return margins.filter { candidates.contains($0.rule) }.compactMap(\.seconds).min()
    }
}
