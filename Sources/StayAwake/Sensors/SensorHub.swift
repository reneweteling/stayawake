import Foundation
import StayAwakeCore

/// Everything the sensors saw in one pass, with the details --report prints.
struct SensorReading {
    var snapshot: Snapshot
    var hidAll: [(name: String, celsius: Double?)]
    var classification: HIDClassification
    var family: ChipFamily
    /// Raw SMC keys that were read: the curated ones, or every Tp/Te/Tf/Tg
    /// key when the hub scanned (--report, or the unknown-chip fallback).
    var smcKeys: [SMCKey]
    var cpu: TemperatureChoice
    var gpu: TemperatureChoice
    var batteryRaw: BatterySample?
    var pmset: PmsetSettings?

    var cpuSource: String { cpu.source }
    var gpuSource: String { gpu.source }
}

/// Builds a core `Snapshot` from the real sensors.
final class SensorHub: @unchecked Sendable {
    private let hid = HIDSensorReader()
    private lazy var smc = SMCReader()
    private let load = CPULoadSampler()
    let network = NetworkWatcher()
    var preference: SensorPreference
    let family = ChipFamily.detect(brand: SensorReport.sysctl("machdep.cpu.brand_string"))

    /// Set by the app when it saw a wake notification; cleared by `read`.
    var didWake = false

    init(preference: SensorPreference = .automatic) {
        self.preference = preference
        _ = load.sample()
    }

    private var waitedForNetwork = false

    /// The first NWPath update arrives a moment after launch; without this the
    /// first snapshot would say "no network".
    func waitForNetworkOnce() {
        guard !waitedForNetwork else { return }
        waitedForNetwork = true
        network.waitForFirstPath()
    }

    /// `scanSMC` reads every Tp/Te/Tf/Tg key instead of only the curated
    /// ones, for the --report table.
    func read(scanSMC: Bool = false) -> SensorReading {
        let useHID = preference == .automatic || preference == .hid
        let useSMC = preference == .automatic || preference == .smc
        let hidAll = useHID ? hid.readAll() : []
        let classification = HIDSensorParser.classify(hidAll.compactMap { r in r.celsius.map { HIDSensor(name: r.name, celsius: $0) } })

        // Which keys count, and how HID and SMC are combined, is decided in
        // core: SensorCombine.choose. HID tdie on the M2 Max lags (45 to 50 C
        // while the per-core SMC keys go 58 to 71 C), so it is the cross-check,
        // not the main source. The M2 Max has no HID GPU sensor.
        var smcKeys: [SMCKey] = []
        if useSMC, let smc {
            smcKeys = scanSMC ? smc.scan(prefixes: SMCTemperatureKeys.scanPrefixes)
                : smc.read(keys: SensorCombine.curatedKeys(.cpu, family: family) + SensorCombine.curatedKeys(.gpu, family: family))
        }
        func choose() -> (TemperatureChoice, TemperatureChoice) {
            (SensorCombine.choose(.cpu, hid: classification.cpuTemperature, smc: smcKeys, family: family, useHID: useHID, useSMC: useSMC),
             SensorCombine.choose(.gpu, hid: classification.gpuTemperature, smc: smcKeys, family: family, useHID: useHID, useSMC: useSMC))
        }
        var (cpu, gpu) = choose()
        // Unknown chip, or none of its keys readable, and HID silent: scan so
        // the fallback has keys to look at.
        if useSMC, !scanSMC, cpu.value == nil || gpu.value == nil, let smc {
            smcKeys = smc.scan(prefixes: SMCTemperatureKeys.scanPrefixes)
            (cpu, gpu) = choose()
        }
        if preference == .thermalStateOnly {
            cpu = .none; gpu = .none
        }

        let rawBattery = IORegistryReader.battery()
        let battery = rawBattery?.temperature ?? classification.batteryTemperature
        let power = PowerSourceReading.read()
        let wake = didWake
        didWake = false

        let snap = Snapshot(cpuTemperature: cpu.value, gpuTemperature: gpu.value, batteryTemperature: battery,
                            thermal: thermalLevel(ProcessInfo.processInfo.thermalState),
                            batteryPercent: power.percent, powerSource: power.source, isCharging: power.isCharging,
                            lidClosed: IORegistryReader.lidClosed() ?? false,
                            cpuLoadPercent: load.sample(), watchedProcessRunning: nil,
                            networkUsable: network.usable, didWake: wake)
        let pmset = ReadOnlyCommand.pmsetG().map(PmsetParser.parse)
        return SensorReading(snapshot: snap, hidAll: hidAll, classification: classification, family: family,
                             smcKeys: smcKeys, cpu: cpu, gpu: gpu, batteryRaw: rawBattery, pmset: pmset)
    }
}
