import Darwin
import Foundation
import os
import Security
import StayAwakeCore

// StayAwakeHelper: the root launchd daemon, registered by the app with
// SMAppService.daemon. It listens on one XPC Mach service, accepts only the
// signed StayAwake app, owns the lease and runs exactly the two fixed pmset
// argv arrays from PmsetCommand. All decisions live in HelperEngine
// (StayAwakeCore); this file is the system glue.

let logger = Logger(subsystem: HelperIdentity.helperIdentifier, category: "helper")

#if DEBUG
/// Debug builds accept a client by identifier alone, so two ad-hoc signed
/// builds can talk. Release builds never compile this in.
let relaxedRequirement = true
#else
let relaxedRequirement = false
#endif

// MARK: - Process runner

/// posix_spawn with a fixed argv, an empty environment and no inherited file
/// descriptors. No shell is involved.
enum Spawn {
    struct Result { var status: Int32?; var output: Data }

    static func run(_ argv: [String], capture: Bool, timeout: TimeInterval = 10) -> Result {
        guard let path = argv.first, path.hasPrefix("/") else { return Result(status: nil, output: Data()) }
        var fds: [Int32] = [-1, -1]
        if capture, pipe(&fds) != 0 { return Result(status: nil, output: Data()) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        if capture {
            posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        } else {
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        }
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Close every descriptor in the child except the three set above.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }
        let emptyEnvironment: [UnsafeMutablePointer<CChar>?] = [nil]

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attr, cArgs, emptyEnvironment)
        if capture { close(fds[1]) }
        guard rc == 0 else {
            if capture { close(fds[0]) }
            logger.error("posix_spawn \(path, privacy: .public) failed: \(rc)")
            return Result(status: nil, output: Data())
        }

        let deadline = Date().addingTimeInterval(timeout)
        var output = Data()
        if capture {
            var buffer = [UInt8](repeating: 0, count: 4096)
            var pfd = pollfd(fd: fds[0], events: Int16(POLLIN), revents: 0)
            while Date() < deadline {
                let ready = poll(&pfd, 1, 200)
                if ready < 0 { if errno == EINTR { continue } else { break } }
                if ready == 0 { continue }
                let n = read(fds[0], &buffer, buffer.count)
                if n <= 0 { break }
                if output.count < 65_536 { output.append(buffer, count: n) }
            }
            close(fds[0])
        }

        var status: Int32 = 0
        while true {
            let w = waitpid(pid, &status, WNOHANG)
            if w == pid { break }
            if w == -1, errno != EINTR { return Result(status: nil, output: output) }
            if Date() >= deadline {
                kill(pid, SIGKILL)
                _ = waitpid(pid, &status, 0)
                logger.error("\(path, privacy: .public) timed out and was killed")
                return Result(status: nil, output: output)
            }
            usleep(20_000)
        }
        // WIFEXITED / WEXITSTATUS by hand; a signal counts as 128 + signal.
        let signal = status & 0x7f
        let code = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        return Result(status: code, output: output)
    }
}

// MARK: - State file

struct StateFileError: Error, CustomStringConvertible {
    var description: String
}

/// /var/db/stayawake/state.json, root owned, 0600, in a root owned 0700 directory.
/// Symlinks are refused at every step.
enum StateFile {
    static let directory = HelperIdentity.stateDirectory
    static let path = HelperIdentity.statePath

    static func ensureDirectory() throws {
        if mkdir(directory, 0o700) != 0, errno != EEXIST {
            throw StateFileError(description: "mkdir \(directory): errno \(errno)")
        }
        var st = stat()
        guard lstat(directory, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == 0 else {
            throw StateFileError(description: "\(directory) is not a root owned directory")
        }
        if st.st_mode & 0o777 != 0o700 { chmod(directory, 0o700) }
    }

    static func load() -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == 0, st.st_size <= 65_536 else {
            logger.error("state file ignored: not a small root owned regular file")
            return nil
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            data.append(buffer, count: n)
            if data.count > 65_536 { return nil }
        }
        return data
    }

    static func save(_ data: Data) throws {
        try ensureDirectory()
        let tmp = path + ".tmp"
        unlink(tmp)
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StateFileError(description: "open \(tmp): errno \(errno)") }
        fchmod(fd, 0o600)
        let ok = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        fsync(fd)
        close(fd)
        guard ok, rename(tmp, path) == 0 else {
            unlink(tmp)
            throw StateFileError(description: "write \(path) failed: errno \(errno)")
        }
    }
}

// MARK: - System facts

func bootSessionUUID() -> String? {
    var size = 0
    guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1, size < 256 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
    let value = String(cString: buffer)
    return value.isEmpty ? nil : value
}

/// The cdhash of this executable as signed on disk, read once at startup.
func ownCodeHash() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
          let dict = info as? [String: Any],
          let unique = dict[kSecCodeInfoUnique as String] as? Data else { return nil }
    return unique.map { String(format: "%02x", $0) }.joined()
}

/// The version of the app bundle this helper runs from (Contents/MacOS/..).
func bundleVersion() -> String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
}

func monotonicSeconds() -> TimeInterval {
    Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9
}

// MARK: - Effects

final class SystemEffects: HelperEffects {
    private var cachedSleepDisabled: (value: Bool?, at: TimeInterval)?

    func run(_ command: PmsetCommand) -> Int32? {
        cachedSleepDisabled = nil
        return Spawn.run(command.argv, capture: false).status
    }

    func readSleepDisabled() -> Bool? {
        let now = monotonicSeconds()
        if let cached = cachedSleepDisabled, now - cached.at < 2 { return cached.value }
        let result = Spawn.run(PmsetCommand.readSettingsArgv, capture: true)
        let value = result.status == 0 ? PmsetParser.parse(String(decoding: result.output, as: UTF8.self)).sleepDisabled : nil
        cachedSleepDisabled = (value, now)
        return value
    }

    func loadState() -> Data? { StateFile.load() }

    func saveState(_ data: Data) throws { try StateFile.save(data) }

    func log(_ message: String, isError: Bool) {
        if isError {
            logger.error("\(message, privacy: .public)")
        } else {
            logger.notice("\(message, privacy: .public)")
        }
    }
}

// MARK: - Listener

/// One connection at a time: a new, verified connection replaces the old one.
/// That keeps a relaunched app (or `StayAwake --restore`) from being locked
/// out by a connection that has not been torn down yet.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let engine: HelperEngine
    private let queue: DispatchQueue
    private var current: NSXPCConnection?

    init(engine: HelperEngine, queue: DispatchQueue) {
        self.engine = engine
        self.queue = queue
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // The listener requirement already applies; setting it on the
        // connection as well checks the audit token of every message.
        connection.setCodeSigningRequirement(HelperIdentity.clientRequirement(relaxed: relaxedRequirement))
        connection.exportedInterface = .stayAwakeHelper()
        connection.exportedObject = HelperConnectionHandler(engine: engine, queue: queue, clock: monotonicSeconds)
        let pid = connection.processIdentifier
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let self else { return }
            self.queue.async {
                if self.current === connection { self.current = nil }
                logger.notice("connection from pid \(pid) closed; the lease runs out unless a heartbeat arrives")
            }
        }
        queue.sync {
            let previous = current
            current = connection
            if let previous {
                logger.notice("new connection from pid \(pid) replaces pid \(previous.processIdentifier)")
                previous.invalidate()
            } else {
                logger.notice("connection from pid \(pid) accepted")
            }
        }
        connection.resume()
        return true
    }
}

// MARK: - Main

if CommandLine.arguments.contains("--version") {
    // Read-only, for checks after a build. Needs no root.
    print("StayAwakeHelper \(bundleVersion()) cdhash \(ownCodeHash() ?? "unknown")")
    exit(0)
}

guard geteuid() == 0 else {
    FileHandle.standardError.write(Data("StayAwakeHelper runs as a launchd daemon (root), started by StayAwake.\n".utf8))
    exit(1)
}

let queue = DispatchQueue(label: "com.weteling.stayawake.helper.engine")
let boot = bootSessionUUID()
let engine = HelperEngine(effects: SystemEffects(), version: bundleVersion(), codeHash: ownCodeHash(),
                          bootSession: { boot })
logger.notice("starting, version \(engine.version, privacy: .public), boot \(boot ?? "unknown", privacy: .public)")
queue.sync { engine.start() }

// Wall clock timer, so a lease that ran out while the Mac slept ends right
// after wake.
let timer = DispatchSource.makeTimerSource(queue: queue)
timer.schedule(wallDeadline: .now() + 5, repeating: 5, leeway: .seconds(1))
timer.setEventHandler { engine.tick() }
timer.resume()

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
    source.setEventHandler {
        logger.notice("signal \(sig), stopping")
        engine.shutdown()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

let listener = NSXPCListener(machServiceName: HelperIdentity.machServiceName)
listener.setConnectionCodeSigningRequirement(HelperIdentity.clientRequirement(relaxed: relaxedRequirement))
let listenerDelegate = ListenerDelegate(engine: engine, queue: queue)
listener.delegate = listenerDelegate
listener.resume()

dispatchMain()
