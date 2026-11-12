import Foundation
import ServiceManagement
import StayAwakeCore

/// The user's settings on `UserDefaults`. The core never sees this class:
/// it receives `config`, a plain value that is clamped to the spec ranges.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    /// Safety rules, schedule, notifications (including the unplug alert) and
    /// advanced values. Stored as JSON so older versions migrate by default.
    @Published var config: Config {
        didSet {
            let clamped = config.clamped()
            if clamped != config { config = clamped; return }
            if let data = try? JSONEncoder().encode(config) { defaults.set(data, forKey: "config") }
        }
    }
    @Published var crashReports: Bool { didSet { defaults.set(crashReports, forKey: "crashReports") } }
    /// Settings that only the app cares about (display and start-up), kept out of `Config`.
    @Published var startArmed: Bool { didSet { defaults.set(startArmed, forKey: "startArmed") } }
    @Published var clearLeftoverOnLaunch: Bool { didSet { defaults.set(clearLeftoverOnLaunch, forKey: "clearLeftoverOnLaunch") } }
    @Published var menuBarReadout: MenuBarReadout { didSet { defaults.set(menuBarReadout.rawValue, forKey: "menuBarReadout") } }
    @Published var temperatureUnit: TemperatureUnit { didSet { defaults.set(temperatureUnit.rawValue, forKey: "temperatureUnit") } }
    /// Name of a system sound to play on a trip. Empty means silent.
    @Published var tripSound: String { didSet { defaults.set(tripSound, forKey: "tripSound") } }
    @Published var launchAtLogin: Bool

    private init() {
        defaults.register(defaults: [
            "crashReports": true, "startArmed": false, "clearLeftoverOnLaunch": true,
            "menuBarReadout": MenuBarReadout.both.rawValue, "temperatureUnit": TemperatureUnit.celsius.rawValue,
            "tripSound": "",
        ])
        if let data = defaults.data(forKey: "config"), let stored = try? Config.decodeLenient(from: data) {
            config = stored
        } else {
            config = Config()
        }
        crashReports = defaults.bool(forKey: "crashReports")
        startArmed = defaults.bool(forKey: "startArmed")
        clearLeftoverOnLaunch = defaults.bool(forKey: "clearLeftoverOnLaunch")
        menuBarReadout = MenuBarReadout(rawValue: defaults.string(forKey: "menuBarReadout") ?? "") ?? .both
        temperatureUnit = TemperatureUnit(rawValue: defaults.string(forKey: "temperatureUnit") ?? "") ?? .celsius
        tripSound = defaults.string(forKey: "tripSound") ?? ""
        launchAtLogin = Bundle.main.bundleIdentifier != nil && SMAppService.mainApp.status == .enabled
    }

    /// Notifications tab: "Alert when unplugged while armed".
    var alertOnUnplug: Bool {
        get { config.alertOnUnplug }
        set { config.alertOnUnplug = newValue }
    }

    /// Open at login through SMAppService. Needs the app bundle.
    func setLaunchAtLogin(_ on: Bool) {
        guard Bundle.main.bundleIdentifier != nil else { launchAtLogin = false; return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("StayAwake: launch at login failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
