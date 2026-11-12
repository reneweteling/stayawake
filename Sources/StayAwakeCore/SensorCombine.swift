import Foundation

/// Combines readings of one quantity that come from different sensor
/// families. Pure, so the choice is tested instead of trusted.
public enum SensorCombine {
    /// Readings outside this range are a broken sensor, not a temperature.
    public static let plausible: ClosedRange<Double> = 1...130

    /// Above this gap between HID and the curated SMC keys the source line
    /// says so.
    public static let disagreement: Double = 15

    /// The hottest plausible reading, or nil when none is plausible.
    public static func hottest(_ readings: [Double?]) -> Double? {
        readings.compactMap { $0 }.filter { plausible.contains($0) }.max()
    }

    /// Battery temperature: the hottest of IORegistry `Temperature`,
    /// `VirtualTemperature` and the HID gas gauge. On an M2 Max the plain
    /// `Temperature` reads 4 to 5 C below the other two, and macOS stops
    /// charging at a gas gauge of about 44 C, so the max is the honest one.
    public static func battery(temperature: Double?, virtual: Double?, hid: Double?) -> Double? {
        hottest([temperature, virtual, hid])
    }

    public enum Quantity: String, Sendable { case cpu, gpu }

    /// SMC keys that count for the quantity, before any value is looked at.
    public static func curatedKeys(_ q: Quantity, family: ChipFamily) -> [String] {
        q == .cpu ? SMCTemperatureKeys.cpu(family) : SMCTemperatureKeys.gpu(family)
    }

    /// Picks the instant temperature for one quantity. The engine smooths it.
    ///
    /// 1. The curated keys of the chip family that pass the gate: their mean.
    ///    The max of single cores swings 30 C within seconds under normal
    ///    work; the mean is the die temperature that matters for heat.
    /// 2. None of those readable (unknown chip, or SMC skipped this sample):
    ///    HID (`PMU tdie*` max). On a known chip the engine covers short SMC
    ///    gaps with the last SMC value, so HID only takes over after a minute.
    /// 3. HID silent too: the max over every key with the family prefixes.
    ///    That reads high, which is the safe side when nothing better exists.
    ///
    /// With both families readable, HID is only a cross-check in the source text.
    /// `useHID` / `useSMC` implement the "hid" and "smc" sensor modes.
    public static func choose(_ q: Quantity, hid: Double?, smc all: [SMCKey], family: ChipFamily,
                              useHID: Bool = true, useSMC: Bool = true) -> TemperatureChoice {
        let hidValue = useHID ? hid.flatMap { plausible.contains($0) ? $0 : nil } : nil
        let wanted = Set(curatedKeys(q, family: family))
        let ok = { (k: SMCKey) in SMCTemperatureKeys.plausible.contains(k.celsius) }
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        let crossCheck = { (smc: Double) -> String in
            guard let h = hidValue else { return "" }
            let gap = abs(h - smc)
            return ", hid \(f(h)) cross-check" + (gap > disagreement ? ", disagree by \(f(gap)) C" : "")
        }

        if useSMC {
            let curated = all.filter { wanted.contains($0.key) && ok($0) }
            if !curated.isEmpty, let top = curated.max(by: { $0.celsius < $1.celsius }) {
                let mean = curated.map(\.celsius).reduce(0, +) / Double(curated.count)
                let source = "smc mean \(f(mean)) of \(curated.count) \(family.rawValue) keys, max \(f(top.celsius)) \(top.key)" + crossCheck(mean)
                return TemperatureChoice(value: mean, smc: mean, used: curated, source: source, kind: .smc, hid: hidValue)
            }
        }
        if let h = hidValue {
            let why = !useSMC ? "" : family == .unknown ? ", unknown chip" : ", no \(family.rawValue) key readable"
            return TemperatureChoice(value: h, smc: nil, used: [], source: "hid \(f(h))\(why)", kind: .hid, hid: h)
        }
        if useSMC {
            let prefixes = q == .cpu ? SMCTemperatureKeys.fallbackCPUPrefixes : SMCTemperatureKeys.fallbackGPUPrefixes
            let used = all.filter { k in ok(k) && prefixes.contains { k.key.hasPrefix($0) } }
            if let top = used.max(by: { $0.celsius < $1.celsius }) {
                let label = "all \(prefixes.joined(separator: "/")) keys, \(family == .unknown ? "unknown chip" : "no \(family.rawValue) key readable")"
                return TemperatureChoice(value: top.celsius, smc: top.celsius, used: used,
                                         source: "smc max \(f(top.celsius)) \(top.key) (\(label), \(used.count))", kind: .fallback, hid: nil)
            }
        }
        return .none
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
