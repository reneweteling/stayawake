import Foundation

/// One window inside a single day, in minutes since local midnight.
/// The start is inclusive and the end is exclusive. An end of 1440 means midnight.
public struct TimeWindow: Codable, Equatable, Sendable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    public func contains(minuteOfDay m: Int) -> Bool { m >= start && m < end }
}

/// Allowed hours per weekday, in the Mac's time zone. `days[0]` is Sunday,
/// `days[6]` is Saturday. An overnight run is two windows on two days.
public struct Schedule: Codable, Equatable, Sendable {
    public static let maxWindowsPerDay = 3
    public static let stepMinutes = 5

    public var enabled: Bool
    public var days: [[TimeWindow]]

    public init(enabled: Bool = true, days: [[TimeWindow]]) {
        self.enabled = enabled
        self.days = days
    }

    /// Monday to Friday 07:00 to 20:00, nothing on the weekend.
    public static let `default` = Schedule(
        enabled: true,
        days: (0..<7).map { ($0 >= 1 && $0 <= 5) ? [TimeWindow(start: 7 * 60, end: 20 * 60)] : [] }
    )

    /// Always allowed.
    public static let off = Schedule(enabled: false, days: Array(repeating: [], count: 7))

    /// Seven days, windows snapped to 5 minutes, clamped to the day, sorted,
    /// merged when they overlap or touch, at most three per day.
    public func normalized() -> Schedule {
        var out: [[TimeWindow]] = []
        for i in 0..<7 {
            let raw = i < days.count ? days[i] : []
            let snapped = raw.compactMap { w -> TimeWindow? in
                func snap(_ v: Int) -> Int {
                    let c = min(max(v, 0), 1440)
                    return Int((Double(c) / Double(Schedule.stepMinutes)).rounded()) * Schedule.stepMinutes
                }
                let s = snap(w.start), e = snap(w.end)
                return e > s ? TimeWindow(start: s, end: e) : nil
            }.sorted { $0.start < $1.start }
            var merged: [TimeWindow] = []
            for w in snapped {
                if var last = merged.last, w.start <= last.end {
                    last.end = max(last.end, w.end)
                    merged[merged.count - 1] = last
                } else {
                    merged.append(w)
                }
            }
            out.append(Array(merged.prefix(Schedule.maxWindowsPerDay)))
        }
        return Schedule(enabled: enabled, days: out)
    }

    private func calendar(_ tz: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal
    }

    /// True when `date` falls in a window of its weekday. Always true when the
    /// schedule is switched off. Uses the wall clock reading, so a DST change
    /// moves the real time of a window but never its clock time.
    public func isOpen(at date: Date, in tz: TimeZone) -> Bool {
        guard enabled else { return true }
        return window(containing: date, in: tz) != nil
    }

    private func window(containing date: Date, in tz: TimeZone) -> TimeWindow? {
        let cal = calendar(tz)
        let parts = cal.dateComponents([.weekday, .hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let day = ((parts.weekday ?? 1) - 1) % 7
        let windows = day < days.count ? days[day] : []
        return windows.first { $0.contains(minuteOfDay: minute) }
    }

    private func instant(minute: Int, onDayStarting dayStart: Date, cal: Calendar) -> Date {
        if minute >= 1440 { return cal.date(byAdding: .day, value: 1, to: dayStart)! }
        return cal.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: dayStart,
                        matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward) ?? dayStart
    }

    /// When the window that contains `date` ends. Nil when closed, or when the
    /// schedule is off (no end).
    public func currentWindowEnd(at date: Date, in tz: TimeZone) -> Date? {
        guard enabled, let w = window(containing: date, in: tz) else { return nil }
        let cal = calendar(tz)
        return instant(minute: w.end, onDayStarting: cal.startOfDay(for: date), cal: cal)
    }

    /// The first moment at or after `date` when holding is allowed: `date`
    /// itself when open, otherwise the start of the next window. Nil when
    /// no window exists in the coming week.
    public func nextOpen(from date: Date, in tz: TimeZone) -> Date? {
        guard enabled else { return date }
        if isOpen(at: date, in: tz) { return date }
        let cal = calendar(tz)
        let today = cal.startOfDay(for: date)
        for offset in 0...7 {
            guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            let weekday = (cal.component(.weekday, from: day) - 1) % 7
            let windows = weekday < days.count ? days[weekday] : []
            for w in windows.sorted(by: { $0.start < $1.start }) {
                let start = self.instant(minute: w.start, onDayStarting: day, cal: cal)
                if start > date { return start }
            }
        }
        return nil
    }
}
