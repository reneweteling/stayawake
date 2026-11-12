import Foundation
import StayAwakeCore

/// Terminal modes of the app binary:
///
///     StayAwake --simulate scenario.json   runs a scripted scenario through the engine
///     StayAwake --status    read-only summary: SleepDisabled and the readings
///     StayAwake --report    every reading, the raw HID sensor list and the chip
///     StayAwake --restore   asks the backend to turn sleep back on (disablesleep 0)
///     StayAwake --helper-status   read-only: registration state and the helper's status
///
/// Only --restore changes a power setting, and only back to normal sleep.
enum CommandLineMode {
    /// Returns an exit code when a command line mode ran, nil to start the menu bar app.
    static func runIfRequested() -> Int32? {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--simulate") {
            guard i + 1 < args.count else {
                printError("usage: StayAwake --simulate scenario.json")
                return 64
            }
            return simulate(path: args[i + 1])
        }
        if args.contains("--status") { return SensorReport.status() }
        if args.contains("--report") { return SensorReport.report() }
        if args.contains("--restore") { return restore() }
        if args.contains("--helper-status") { return helperStatus() }
        return nil
    }

    /// Calls the backend release. When that fails, prints the manual command.
    private static func restore() -> Int32 {
        let backend = BackendFactory.make()
        do {
            try backend.release(reason: "cli")
        } catch {
            printError("Could not restore sleep with the \(backend.name) backend: \(error)")
            printError("Run this by hand:")
            printError("  \(BackendFactory.manualRestoreCommand)")
            return 1
        }
        let state = ReadOnlyCommand.pmsetG().map(PmsetParser.parse)?.sleepDisabled
        print("Sleep restored. SleepDisabled: \(state.map { $0 ? "1 (still on)" : "0 (off)" } ?? "unknown")")
        return state == true ? 1 : 0
    }

    private static func helperStatus() -> Int32 {
        let backend = BackendFactory.make()
        print("backend: \(backend.name)")
        switch backend.availability() {
        case .ready: print("registration: enabled")
        case .setupRequired(let need): print("registration: \(need.title). \(need.detail)")
        }
        guard let helper = backend as? HelperManaging else { return 0 }
        guard let status = helper.helperStatus() else {
            print("helper: no answer")
            return 1
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(status) { print(String(decoding: data, as: UTF8.self)) }
        switch helper.versionVerdict() {
        case .current: print("version: matches this app")
        case .replace(let why): print("version: differs (\(why)); the app re-registers it on launch")
        case .unknown: print("version: unknown")
        }
        return 0
    }

    private static func simulate(path: String) -> Int32 {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            let results = try Simulator.run(try Simulator.parse(data))
            results.forEach { print($0.line) }
            return 0
        } catch {
            printError("simulate failed: \(error)")
            return 1
        }
    }

    static func printError(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
