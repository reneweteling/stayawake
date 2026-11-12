import Foundation

/// Apple silicon generation, from `machdep.cpu.brand_string`. The SMC key
/// layout changes per generation, not per Pro/Max/Ultra variant.
public enum ChipFamily: String, Sendable, CaseIterable {
    case m1, m2, m3, m4, m5, unknown

    /// "Apple M2 Max" -> .m2. Anything else (Intel, a newer chip) -> .unknown.
    public static func detect(brand: String) -> ChipFamily {
        let words = brand.split(separator: " ")
        guard words.count >= 2, words[0] == "Apple", words[1].hasPrefix("M"),
              let n = Int(words[1].dropFirst()) else { return .unknown }
        return ChipFamily(rawValue: "m\(n)") ?? .unknown
    }
}

/// One SMC temperature key and its value.
public struct SMCKey: Equatable, Sendable {
    public var key: String
    public var celsius: Double
    public init(key: String, celsius: Double) {
        self.key = key
        self.celsius = celsius
    }
}

/// Which SMC keys are CPU and GPU die temperatures, per chip family.
///
/// The lists are the per-core keys the Stats app uses (exelban/stats,
/// Modules/Sensors/values.swift). On Apple silicon every sensor shows up as a
/// group of keys: a base reading, the base plus a fixed offset, and a hotter
/// estimate. On an M2 Max a power gated cluster reads base 0.00 while the
/// other two read their bare offsets (4.6 to 8.4). Taking the max over every
/// Tp key therefore always lands on an estimate key, 10 to 15 C above the
/// per-core value. The curated keys are the middle ones.
public enum SMCTemperatureKeys {
    /// Prefixes walked for `--report` and for the unknown-chip fallback.
    public static let scanPrefixes = ["Tp", "Te", "Tf", "Tg"]
    public static let fallbackCPUPrefixes = ["Tp", "Te"]
    public static let fallbackGPUPrefixes = ["Tg"]

    /// A die below 10 C is a gated sensor reporting its offset, not a reading.
    public static let plausible: ClosedRange<Double> = 10...130

    public static func cpu(_ family: ChipFamily) -> [String] {
        switch family {
        case .m1: return ["Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b", // performance
                          "Tp09", "Tp0T"]                                                 // efficiency
        case .m2: return ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j",
                          "Tp1h", "Tp1t", "Tp1p", "Tp1l"]
        case .m3: return ["Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E",
                          "Te05", "Te0L", "Te0P", "Te0S"]
        case .m4: return ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e",
                          "Te05", "Te0S", "Te09", "Te0H"]
        case .m5: return ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K",                 // super
                          "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"]
        case .unknown: return []
        }
    }

    public static func gpu(_ family: ChipFamily) -> [String] {
        switch family {
        case .m1: return ["Tg05", "Tg0D", "Tg0L", "Tg0T"]
        case .m2: return ["Tg0f", "Tg0j"]
        case .m3: return ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"]
        case .m4: return ["Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"]
        case .m5: return ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"]
        case .unknown: return []
        }
    }

    /// Parses `key = value` lines (the fixtures and the `--report` table).
    /// Lines starting with `#` and lines without a number are skipped.
    public static func parse(_ text: String) -> [SMCKey] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { return nil }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0].count == 4,
                  let v = Double(parts[1].split(separator: " ").first ?? "") else { return nil }
            return SMCKey(key: parts[0], celsius: v)
        }
    }
}

/// The outcome for one quantity (CPU or GPU): the value the rules see, the
/// SMC keys it came from, and a short source line for `--report`.
public struct TemperatureChoice: Equatable, Sendable {
    public var value: Double?
    /// Max over the SMC keys that were used, nil when none was.
    public var smc: Double?
    /// The SMC keys behind `smc`, plausible ones only.
    public var used: [SMCKey]
    public var source: String
    public init(value: Double?, smc: Double?, used: [SMCKey], source: String) {
        self.value = value
        self.smc = smc
        self.used = used
        self.source = source
    }

    public static let none = TemperatureChoice(value: nil, smc: nil, used: [], source: "none")
}
