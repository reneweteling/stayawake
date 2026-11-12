import Foundation
import StayAwakeCore

/// Terminal modes of the app binary:
///
///     StayAwake --simulate scenario.json   runs a scripted scenario through the engine
///     StayAwake --status    read-only summary: SleepDisabled and the readings
///     StayAwake --report    every reading, the raw HID sensor list and the chip
///     StayAwake --restore   asks the backend to turn sleep back on (disablesleep 0)
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
        return nil
    }

    /// Calls the backend release. When that fails, prints the manual command.
    private static func restore() -> Int32 {
        let backend = BackendFactory.make()
        do {
            try backend.release()
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
