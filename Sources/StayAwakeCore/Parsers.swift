import Foundation

// Pure parsers for text the sensors layer reads from the system. No system
// calls here, so they run against fixtures captured on a real Mac.

/// `pmset -g` output (read-only).
public struct PmsetSettings: Equatable, Sendable {
    /// Every "name value" line; the value is the first word after the name.
    public var values: [String: String]
    /// The system-wide SleepDisabled flag. Nil when the line is missing.
    public var sleepDisabled: Bool?
    /// Processes named in "sleep prevented by ..." on the sleep line.
    public var sleepPreventedBy: [String]

    public init(values: [String: String] = [:], sleepDisabled: Bool? = nil, sleepPreventedBy: [String] = []) {
        self.values = values
        self.sleepDisabled = sleepDisabled
        self.sleepPreventedBy = sleepPreventedBy
    }
}

public enum PmsetParser {
    public static func parse(_ text: String) -> PmsetSettings {
        var out = PmsetSettings()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasSuffix(":") { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2 else { continue }
            let name = String(parts[0])
            let rest = parts[1].trimmingCharacters(in: .whitespaces)
            // "Sleep On Power Button 1" has a multi-word name; keep the last
            // word as the value when the first word is capitalised prose.
            let value = rest.split(separator: " ").first.map(String.init) ?? rest
            if out.values[name] == nil { out.values[name] = value }
            if name == "SleepDisabled" { out.sleepDisabled = (value == "1") }
            if name == "sleep", let r = rest.range(of: "sleep prevented by ") {
                let list = rest[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ") "))
                var seen: [String] = []
                for p in list.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !p.isEmpty && !seen.contains(p) {
                    seen.append(p)
                }
                out.sleepPreventedBy = seen
            }
        }
        return out
    }
}

/// The top-level properties of `ioreg -rn AppleSmartBattery`.
public struct BatterySample: Equatable, Sendable {
    /// Hundredths of a degree Celsius as ioreg prints it.
    public var rawTemperature: Int?
    public var rawVirtualTemperature: Int?
    public var currentCapacity: Int?
    public var maxCapacity: Int?
    public var isCharging: Bool?
    public var externalConnected: Bool?

    public init(rawTemperature: Int? = nil, rawVirtualTemperature: Int? = nil, currentCapacity: Int? = nil,
                maxCapacity: Int? = nil, isCharging: Bool? = nil, externalConnected: Bool? = nil) {
        self.rawTemperature = rawTemperature
        self.rawVirtualTemperature = rawVirtualTemperature
        self.currentCapacity = currentCapacity
        self.maxCapacity = maxCapacity
        self.isCharging = isCharging
        self.externalConnected = externalConnected
    }

    /// Verified on Apple Silicon: the raw value is hundredths of a degree.
    public static func celsius(fromRaw raw: Int) -> Double { Double(raw) / 100 }

    public var temperature: Double? { rawTemperature.map(Self.celsius(fromRaw:)) }
    /// Same unit as `Temperature`; reads 4 to 5 C higher on an M2 Max.
    public var virtualTemperature: Double? { rawVirtualTemperature.map(Self.celsius(fromRaw:)) }
}

public enum IORegBatteryParser {
    public static func parse(_ text: String) -> BatterySample {
        var props: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: " |\t"))
            guard line.hasPrefix("\""), let r = line.range(of: "\" = ") else { continue }
            let key = String(line[line.index(after: line.startIndex)..<r.lowerBound])
            if props[key] == nil { props[key] = String(line[r.upperBound...]) }
        }
        func int(_ k: String) -> Int? { props[k].flatMap { Int($0) } }
        func bool(_ k: String) -> Bool? {
            switch props[k] { case "Yes": return true; case "No": return false; default: return nil }
        }
        return BatterySample(rawTemperature: int("Temperature"), rawVirtualTemperature: int("VirtualTemperature"),
                             currentCapacity: int("CurrentCapacity"), maxCapacity: int("MaxCapacity"),
                             isCharging: bool("IsCharging"), externalConnected: bool("ExternalConnected"))
    }
}

/// One HID temperature service.
public struct HIDSensor: Equatable, Sendable {
    public var name: String
    public var celsius: Double
    public init(name: String, celsius: Double) {
        self.name = name
        self.celsius = celsius
    }
}

public struct HIDClassification: Equatable, Sendable {
    public var cpu: [HIDSensor] = []
    public var gpu: [HIDSensor] = []
    public var battery: [HIDSensor] = []
    public var other: [HIDSensor] = []
    /// Readings outside the plausible range (sensor off or not ready).
    public var invalid: [HIDSensor] = []

    public var cpuTemperature: Double? { cpu.map(\.celsius).max() }
    public var gpuTemperature: Double? { gpu.map(\.celsius).max() }
    public var batteryTemperature: Double? { battery.map(\.celsius).max() }
}

public enum HIDSensorParser {
    /// Plausible range for a die or battery sensor reading.
    public static let validRange: ClosedRange<Double> = 1...150

    /// Matched by prefix because names differ per chip. Checked in order:
    /// GPU first, so a name never counts for both.
    public static let gpuPrefixes = ["GPU MTR Temp"]
    public static let cpuPrefixes = ["PMU tdie", "pACC MTR Temp", "eACC MTR Temp"]
    public static let batteryPrefixes = ["gas gauge battery", "battery"]

    /// Parses the sensor lines of `--report`: `name = value`, one per line.
    /// Lines without " = " are ignored.
    public static func parse(_ text: String) -> [HIDSensor] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let r = line.range(of: " = ", options: .backwards),
                  let v = Double(line[r.upperBound...].trimmingCharacters(in: .whitespaces)) else { return nil }
            let name = String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : HIDSensor(name: name, celsius: v)
        }
    }

    public static func classify(_ sensors: [HIDSensor]) -> HIDClassification {
        var out = HIDClassification()
        for s in sensors {
            guard validRange.contains(s.celsius) else { out.invalid.append(s); continue }
            let lower = s.name.lowercased()
            func match(_ prefixes: [String]) -> Bool { prefixes.contains { lower.hasPrefix($0.lowercased()) } }
            if match(gpuPrefixes) { out.gpu.append(s) }
            else if match(batteryPrefixes) { out.battery.append(s) }
            else if match(cpuPrefixes) { out.cpu.append(s) }
            else { out.other.append(s) }
        }
        return out
    }
}
