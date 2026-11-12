import Foundation

/// Combines readings of one quantity that come from different sensor
/// families. Pure, so the choice is tested instead of trusted.
public enum SensorCombine {
    /// Readings outside this range are a broken sensor, not a temperature.
    public static let plausible: ClosedRange<Double> = 1...130

    /// Above this gap between HID and the curated SMC keys the source line
    /// says so. The hotter one still wins.
    public static let disagreement: Double = 15

    /// The hottest plausible reading, or nil when none is plausible.
    public static func hottest(_ readings: [Double?]) -> Double? {
        readings.compactMap { $0 }.filter { plausible.contains($0) }.max()
    }

    /// CPU temperature from two already reduced values. Fails toward hot.
    public static func cpu(hid: Double?, smc: Double?) -> Double? { hottest([hid, smc]) }

    /// GPU temperature from two already reduced values. The GPU rule never
    /// decides sensor failure, so a nil here is fine.
    public static func gpu(hid: Double?, smc: Double?) -> Double? { hottest([hid, smc]) }

    public enum Quantity: String, Sendable { case cpu, gpu }

    /// SMC keys that count for the quantity, before any value is looked at.
    public static func curatedKeys(_ q: Quantity, family: ChipFamily) -> [String] {
        q == .cpu ? SMCTemperatureKeys.cpu(family) : SMCTemperatureKeys.gpu(family)
    }

    /// Picks the temperature for one quantity.
    ///
    /// 1. The curated per-core keys of the chip family, max over the plausible ones.
    /// 2. HID (`PMU tdie*` max on M2) as the cross-check: the higher of the two wins,
    ///    so a stuck or lagging family never hides heat from the other.
    /// 3. Chip unknown or none of its keys readable: HID alone. Only when HID has
    ///    nothing either, the max over every key with the family prefixes. That
    ///    reads high, which is the safe side when nothing better exists.
    ///
    /// `useHID` / `useSMC` implement the "hid" and "smc" sensor modes.
    public static func choose(_ q: Quantity, hid: Double?, smc all: [SMCKey], family: ChipFamily,
                              useHID: Bool = true, useSMC: Bool = true) -> TemperatureChoice {
        let hidValue = useHID ? hid.flatMap { plausible.contains($0) ? $0 : nil } : nil
        let wanted = Set(curatedKeys(q, family: family))
        let ok = { (k: SMCKey) in SMCTemperatureKeys.plausible.contains(k.celsius) }
        var used: [SMCKey] = []
        var label = ""
        if useSMC {
            let curated = all.filter { wanted.contains($0.key) && ok($0) }
            if !curated.isEmpty {
                used = curated
                label = "\(family.rawValue) keys"
            } else if hidValue == nil {
                let prefixes = q == .cpu ? SMCTemperatureKeys.fallbackCPUPrefixes : SMCTemperatureKeys.fallbackGPUPrefixes
                used = all.filter { k in ok(k) && prefixes.contains { k.key.hasPrefix($0) } }
                label = "all \(prefixes.joined(separator: "/")) keys, \(family == .unknown ? "unknown chip" : "no \(family.rawValue) key readable")"
            }
        }
        let top = used.max { $0.celsius < $1.celsius }
        let smcValue = top?.celsius
        let value = hottest([hidValue, smcValue])

        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        let smcText = top.map { "smc \(f($0.celsius)) \($0.key) (\(label), \(used.count))" }
        let source: String
        switch (hidValue, smcText) {
        case (nil, nil): source = "none"
        case let (h?, nil): source = "hid \(f(h))"
        case let (nil, s?): source = s
        case let (h?, s?):
            let gap = abs(h - (smcValue ?? h))
            source = "max(hid \(f(h)), \(s))" + (gap > disagreement ? ", disagree by \(f(gap)) C" : "")
        }
        return TemperatureChoice(value: value, smc: smcValue, used: used, source: source)
    }

    /// One row per SMC key for `--report`: key, value, and what it was used for.
    public static func table(_ all: [SMCKey], family: ChipFamily) -> [String] {
        let cpu = Set(curatedKeys(.cpu, family: family)), gpu = Set(curatedKeys(.gpu, family: family))
        return all.map { k in
            var role = cpu.contains(k.key) ? "CPU" : gpu.contains(k.key) ? "GPU" : ""
            if !role.isEmpty && !SMCTemperatureKeys.plausible.contains(k.celsius) { role += " (gated, ignored)" }
            let value = String(format: "%7.2f", k.celsius)
            return role.isEmpty ? "\(k.key) = \(value)" : "\(k.key) = \(value)  <- \(role)"
        }
    }
}
