import Foundation

/// One reading at a monotonic time.
public struct TimedValue: Codable, Equatable, Sendable {
    public var t: TimeInterval
    public var v: Double
    public init(t: TimeInterval, v: Double) {
        self.t = t
        self.v = v
    }
}

/// Engine memory for one smoothed temperature: the samples inside the
/// rolling window and the last SMC value, for the source hold.
public struct SignalTracker: Codable, Equatable, Sendable {
    public var samples: [TimedValue] = []
    public var lastSMC: TimedValue?
    public init() {}
}

/// One temperature as the rules saw it.
public struct SignalReading: Equatable, Sendable {
    /// What the sensors said this sample.
    public var instant: Double?
    /// Rolling mean the rule compares to its limit. Nil when the reading is invalid.
    public var smoothed: Double?
    public var source: TemperatureSource
    /// Samples behind `smoothed`.
    public var samples: Int

    public init(instant: Double?, smoothed: Double?, source: TemperatureSource, samples: Int) {
        self.instant = instant
        self.smoothed = smoothed
        self.source = source
        self.samples = samples
    }

    public static let none = SignalReading(instant: nil, smoothed: nil, source: .none, samples: 0)
}

/// The temperature values of one evaluation, for the popover and `--status`.
public struct Signals: Equatable, Sendable {
    public var cpu: SignalReading
    public var gpu: SignalReading
    /// Battery temperature is not smoothed: `instant == smoothed`.
    public var battery: SignalReading
    /// Rise of the battery temperature inside the heating-up window, when that rule runs.
    public var batteryRise: Double?

    public init(cpu: SignalReading, gpu: SignalReading, battery: SignalReading, batteryRise: Double? = nil) {
        self.cpu = cpu
        self.gpu = gpu
        self.battery = battery
        self.batteryRise = batteryRise
    }

    public static let empty = Signals(cpu: .none, gpu: .none, battery: .none)
}

/// Rolling average and source hold. Pure: the samples live in `EngineState`.
///
/// Measured on an M2 Max under normal agent work: the mean of the curated CPU
/// keys swings 70 to 100 C between samples while its 60 s average stays
/// under 96 C. The limits are set against the average.
public enum Smoothing {
    /// Default width of the rolling window, `Config.smoothingSeconds`.
    public static let window: TimeInterval = 60
    /// How long a missing SMC sample is covered by the last SMC value.
    public static let holdSeconds: TimeInterval = 60
    /// Samples closer together than this replace each other, so a burst of
    /// evaluations (lid events, popover) does not outweigh the steady ones.
    public static let minimumSpacing: TimeInterval = 5

    /// The reading to use for this sample. A fresh SMC value is remembered.
    /// When SMC skipped this sample and HID or the fallback keys answered
    /// instead, and the last SMC value is younger than `holdSeconds`, that
    /// value is repeated. A short SMC hiccup then does not swap to a family
    /// that reads 25 C lower and reset every sustain timer. When nothing
    /// answered at all, nothing is held: the sensor-failure rule sees that
    /// as before.
    public static func hold(_ value: Double?, source: TemperatureSource, tracker: inout SignalTracker,
                            now: TimeInterval) -> (value: Double?, source: TemperatureSource) {
        guard let v = value else { return (nil, .none) }
        if source == .smc {
            if SensorCombine.plausible.contains(v) { tracker.lastSMC = TimedValue(t: now, v: v) }
            return (v, .smc)
        }
        if source != .held, let last = tracker.lastSMC, now >= last.t, now - last.t < holdSeconds {
            return (last.v, .held)
        }
        return (v, source)
    }

    /// Adds a valid reading and returns the mean over the window. A window
    /// of 0 keeps only this reading.
    public static func add(_ value: Double, samples: inout [TimedValue], now: TimeInterval,
                           window: TimeInterval = Smoothing.window) -> Double {
        samples.removeAll { $0.t > now || now - $0.t >= window }
        if let last = samples.last, now - last.t < minimumSpacing { samples.removeLast() }
        samples.append(TimedValue(t: now, v: value))
        return mean(samples)!
    }

    public static func mean(_ samples: [TimedValue]) -> Double? {
        samples.isEmpty ? nil : samples.map(\.v).reduce(0, +) / Double(samples.count)
    }

    /// Battery heating up: adds the reading to the 5 minute history and
    /// returns how far it sits above the coolest reading in that window.
    public static func rise(_ value: Double, history: inout [TimedValue], now: TimeInterval,
                            window: TimeInterval) -> Double {
        history.removeAll { $0.t > now || now - $0.t > window }
        if let last = history.last, now - last.t < minimumSpacing { history.removeLast() }
        history.append(TimedValue(t: now, v: value))
        return value - (history.map(\.v).min() ?? value)
    }
}
