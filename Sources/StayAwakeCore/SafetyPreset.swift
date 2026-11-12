import Foundation

/// One-click sets of safety limits for the Safety tab. A preset only touches
/// the heat and battery limits, their waits and the heating-up rule, and
/// switches the limit rules on; everything else in `Config` stays as it is.
/// Balanced equals the defaults from the spec.
public enum SafetyPreset: String, CaseIterable, Sendable {
    case cautious, balanced, relaxed

    public var title: String {
        switch self {
        case .cautious: return "Cautious"
        case .balanced: return "Balanced"
        case .relaxed: return "Relaxed"
        }
    }

    public var summary: String {
        switch self {
        case .cautious: return "Lets the Mac sleep early. Cooler and keeps more battery, but long jobs stop sooner."
        case .balanced: return "The recommended limits. Safe for a Mac in a bag for most work."
        case .relaxed: return "Keeps going longer under heavy load. Only for a Mac with good airflow."
        }
    }

    private struct Limits {
        let cpu: Double, cpuSustain: Int
        let gpu: Double, gpuSustain: Int
        let battery: Double, batterySustain: Int
        let thermal: ThermalLevel, thermalSustain: Int
        let heating: Bool, heatingRise: Double
        let floor: Int
    }

    /// The one table of preset values. CPU and GPU limits apply to the 60 s
    /// average (Apple Silicon throttles itself around 100 to 108 C). The
    /// battery limits sit below the 44 C where macOS stops charging and the
    /// 45 C Li-ion charge limit. Balanced is `Config()`.
    private var limits: Limits {
        switch self {
        case .cautious:
            return Limits(cpu: 95, cpuSustain: 60, gpu: 90, gpuSustain: 60, battery: 40, batterySustain: 30,
                          thermal: .serious, thermalSustain: 60, heating: true, heatingRise: 2, floor: 30)
        case .balanced:
            return Limits(cpu: 100, cpuSustain: 120, gpu: 95, gpuSustain: 120, battery: 43, batterySustain: 60,
                          thermal: .serious, thermalSustain: 300, heating: false, heatingRise: 2, floor: 20)
        case .relaxed:
            return Limits(cpu: 106, cpuSustain: 180, gpu: 105, gpuSustain: 180, battery: 45, batterySustain: 60,
                          thermal: .critical, thermalSustain: 300, heating: false, heatingRise: 2, floor: 10)
        }
    }

    /// `config` with this preset's limits, the matching rules switched on.
    public func apply(to config: Config) -> Config {
        var c = config
        let l = limits
        c.cpuEnabled = true; c.cpuLimit = l.cpu; c.cpuSustainSeconds = l.cpuSustain
        c.gpuEnabled = true; c.gpuLimit = l.gpu; c.gpuSustainSeconds = l.gpuSustain
        c.batteryTempEnabled = true; c.batteryTempLimit = l.battery; c.batteryTempSustainSeconds = l.batterySustain
        c.thermalEnabled = true; c.thermalLimit = l.thermal; c.thermalSustainSeconds = l.thermalSustain
        c.batteryHeatingEnabled = l.heating; c.batteryHeatingRise = l.heatingRise
        c.floorEnabled = true; c.floorPercent = l.floor
        return c.clamped()
    }

    /// The preset `config` matches, or nil when the user has edited the limits (Custom).
    /// The thermal wait only counts when the thermal limit is below critical,
    /// and the heating rise only when that rule is on: otherwise they do nothing.
    public static func matching(_ config: Config) -> SafetyPreset? {
        allCases.first { preset in
            let p = preset.apply(to: config)
            let thermalWaitMatters = p.thermalLimit < .critical
            return p.cpuEnabled == config.cpuEnabled && p.cpuLimit == config.cpuLimit
                && p.cpuSustainSeconds == config.cpuSustainSeconds
                && p.gpuEnabled == config.gpuEnabled && p.gpuLimit == config.gpuLimit
                && p.gpuSustainSeconds == config.gpuSustainSeconds
                && p.batteryTempEnabled == config.batteryTempEnabled && p.batteryTempLimit == config.batteryTempLimit
                && p.batteryTempSustainSeconds == config.batteryTempSustainSeconds
                && p.thermalEnabled == config.thermalEnabled && p.thermalLimit == config.thermalLimit
                && (!thermalWaitMatters || p.thermalSustainSeconds == config.thermalSustainSeconds)
                && p.batteryHeatingEnabled == config.batteryHeatingEnabled
                && (!p.batteryHeatingEnabled || p.batteryHeatingRise == config.batteryHeatingRise)
                && p.floorEnabled == config.floorEnabled && p.floorPercent == config.floorPercent
        }
    }
}
