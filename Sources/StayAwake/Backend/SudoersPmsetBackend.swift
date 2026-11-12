#if DEBUG
import Darwin
import Foundation
import StayAwakeCore

/// Development backend for M3. Debug builds only, and only active with
/// STAYAWAKE_BACKEND=sudoers. It runs `sudo -n /usr/bin/pmset ...` with the
/// argv from `PmsetCommand`; scripts/dev-sudoers.sh allows exactly those two
/// commands for the current user and nothing else.
///
/// Watchdog. A sudoers rule cannot watch anything, so a killed app would leave
/// SleepDisabled on. To soften that, `hold` starts a small detached shell
/// process (own session) that runs a fixed script. The app touches a heartbeat
/// file every 10 s. The watchdog polls every 5 s and runs the release command
/// when the app process is gone or the file is older than the lease.
///
/// Limits, on purpose not hidden:
/// - It is a best effort process, not a daemon. Nobody restarts it, so
///   `kill -9` on both the app and the watchdog (or `pkill -f stayawake-watchdog`
///   first) leaves sleep disabled.
/// - It dies at logout, and after a reboot nothing releases (whether
///   SleepDisabled survives a reboot is assumption A4, checked in M5).
/// - It sleeps when the Mac sleeps, so it only helps while the Mac is awake.
///   After a wake the app reasserts a hold it still wants.
/// - It needs the sudoers rule to exist; without it the release fails and
///   the watchdog retries every 5 s forever.
/// - Release time after kill -9 is the lease (60 s default) plus up to 5 s.
/// The real fix is the root helper with its lease and boot check (M5).
final class SudoersPmsetBackend: PmsetBackend, @unchecked Sendable {
    let name = "sudoers (dev)"

    private let lock = NSLock()
    private var cached: (BackendAvailability, Date)?
    private let heartbeatURL: URL

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/StayAwake")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        heartbeatURL = dir.appendingPathComponent("dev-heartbeat")
    }

    func availability() -> BackendAvailability {
        lock.lock(); defer { lock.unlock() }
        if let (value, at) = cached, Date().timeIntervalSince(at) < 30 { return value }
        // `sudo -n -l <command>` only asks whether the command is allowed; it runs nothing.
        let allowed = PmsetCommand.allCases.allSatisfy { cmd in
            FixedProcess.run(["/usr/bin/sudo", "-n", "-l"] + cmd.argv)?.status == 0
        }
        let value: BackendAvailability = allowed ? .ready
            : .setupRequired("Dev backend needs the sudoers rule. Run scripts/dev-sudoers.sh once in a terminal.")
        cached = (value, Date())
        return value
    }

    func hold(leaseSeconds: Int) throws {
        try run(.disableSleepOn)
        try writeHeartbeat()
        startWatchdog(leaseSeconds: leaseSeconds)
    }

    func heartbeat(leaseSeconds: Int) {
        try? writeHeartbeat()
    }

    func release() throws {
        defer { lock.lock(); cached = nil; lock.unlock() }
        try run(.disableSleepOff)
        // Removing the file tells the watchdog the release was deliberate.
        try? FileManager.default.removeItem(at: heartbeatURL)
    }

    private func run(_ command: PmsetCommand) throws {
        guard let result = FixedProcess.run(command.sudoArgv) else { throw BackendError("Could not start sudo") }
        guard result.status == 0 else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BackendError("sudo pmset failed (\(result.status)): \(detail.isEmpty ? "no output" : detail)")
        }
    }

    /// The file holds the app pid. The mtime is the heartbeat.
    private func writeHeartbeat() throws {
        try String(getpid()).write(to: heartbeatURL, atomically: true, encoding: .utf8)
    }

    // The script is a constant. The app pid, the file path and the lease are
    // passed as positional arguments ($1 $2 $3), never spliced into the text.
    // The release command inside it is the same fixed argv as PmsetCommand.disableSleepOff.
    // A watchdog whose pid no longer matches the file content is stale (a newer
    // app instance took over) and exits without releasing.
    static let watchdogScript = """
    # stayawake-watchdog
    app="$1"; file="$2"; max="$3"; me="$$"
    while :; do
      /bin/sleep 5
      [ -f "$file" ] || exit 0
      owner=$(/bin/cat "$file" 2>/dev/null)
      [ "$owner" = "$app" ] || exit 0
      now=$(/bin/date +%s)
      mtime=$(/usr/bin/stat -f %m "$file" 2>/dev/null || echo 0)
      age=$((now - mtime))
      alive=1
      kill -0 "$app" 2>/dev/null || alive=0
      if [ "$alive" = 0 ] || [ "$age" -gt "$max" ]; then
        if /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0; then
          /bin/rm -f "$file"
          exit 0
        fi
      fi
    done
    """

    private var watchdogPID: pid_t?

    private func startWatchdog(leaseSeconds: Int) {
        lock.lock(); defer { lock.unlock() }
        if let pid = watchdogPID {
            // waitpid reaps a watchdog that has exited; 0 means it still runs.
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == 0 { return }
        }
        let argv = ["/bin/sh", "-c", Self.watchdogScript, "stayawake-watchdog",
                    String(getpid()), heartbeatURL.path, String(max(30, leaseSeconds))]
        watchdogPID = Self.spawnDetached(argv)
    }

    /// posix_spawn in its own session, stdio on /dev/null, minimal environment.
    /// Own session means a Ctrl-C in the terminal that started the app does
    /// not reach it.
    private static func spawnDetached(_ argv: [String]) -> pid_t? {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let cEnv: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin"), nil]
        defer { cArgs.forEach { free($0) }; cEnv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &actions, &attr, cArgs, cEnv)
        return rc == 0 ? pid : nil
    }
}
#endif
