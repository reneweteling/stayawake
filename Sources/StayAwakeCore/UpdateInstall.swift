import Foundation

/// The steps of an install, each with its own time limit. A step that runs
/// over fails the update with a reason instead of hanging it.
public enum UpdateStage: String, CaseIterable, Sendable {
    case download, verify, restoreSleep, restart

    /// Seconds a step may take. The download is the only slow one.
    public var timeLimit: TimeInterval {
        switch self {
        case .download: return 15 * 60
        case .verify: return 5 * 60
        case .restoreSleep: return 30
        case .restart: return 20
        }
    }

    /// Shown in About and logged with `update_failed`.
    public var title: String {
        switch self {
        case .download: return "Downloading"
        case .verify: return "Checking"
        case .restoreSleep: return "Restoring sleep"
        case .restart: return "Restarting"
        }
    }
}

public struct UpdateTimeout: LocalizedError, Equatable {
    public let stage: UpdateStage
    public let seconds: TimeInterval
    public init(stage: UpdateStage, seconds: TimeInterval) {
        self.stage = stage
        self.seconds = seconds
    }
    public var errorDescription: String? { "\(stage.title) took longer than \(Int(seconds)) s" }
}

/// Runs `operation` and gives up after `seconds`. Unlike a task group this
/// returns at the deadline even when the operation ignores cancellation: the
/// operation is cancelled and left to finish on its own.
public func withUpdateTimeout<T: Sendable>(_ stage: UpdateStage, seconds: TimeInterval? = nil,
                                           _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let limit = seconds ?? stage.timeLimit
    let gate = ResumeOnce<T>()
    return try await withCheckedThrowingContinuation { continuation in
        gate.continuation = continuation
        let work = Task {
            do { gate.resume(.success(try await operation())) } catch { gate.resume(.failure(error)) }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, limit) * 1_000_000_000))
            if gate.resume(.failure(UpdateTimeout(stage: stage, seconds: limit))) { work.cancel() }
        }
    }
}

/// Resumes a continuation exactly once, from whichever side gets there first.
final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var continuation: CheckedContinuation<T, Error>?

    @discardableResult
    func resume(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        guard !done, let continuation else { lock.unlock(); return false }
        done = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
        return true
    }
}

/// The detached shell that swaps the bundles after StayAwake quits.
///
/// Arguments: `$0` pid to wait for, `$1` installed app, `$2` staged app,
/// `$3` work folder, `$4` events.jsonl, `$5` seconds to wait, `$6` opener.
/// It gives up (and logs `update_failed`) when the app does not quit in
/// time, and puts the old app back when the new one cannot be moved in.
public enum SwapScript {
    /// How long the shell waits for StayAwake to quit before giving up.
    public static let waitLimit = 120

    public static let source = """
    pid="$0"; current="$1"; staged="$2"; work="$3"; log="$4"; limit="$5"; opener="$6"
    fail() {
      printf '{"event":"update_failed","message":"Update failed: %s","ts":"%s"}\\n' \\
        "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$log"
    }
    ticks=0
    while kill -0 "$pid" 2>/dev/null; do
      if [ "$ticks" -ge $((limit * 5)) ]; then
        fail "StayAwake did not quit within ${limit} s, nothing was replaced"
        rm -rf "$work"
        exit 1
      fi
      sleep 0.2
      ticks=$((ticks + 1))
    done
    backup="$current.old-$$"
    if ! mv "$current" "$backup"; then
      fail "Could not move the old app aside"
      rm -rf "$work"
      "$opener" "$current"
      exit 1
    fi
    if ! mv "$staged" "$current"; then
      mv "$backup" "$current"
      fail "Could not move the new app into place, the old one is back"
      rm -rf "$work"
      "$opener" "$current"
      exit 1
    fi
    rm -rf "$backup" "$work"
    printf '{"event":"update_swapped","message":"Update installed, starting the new version","ts":"%s"}\\n' \\
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$log"
    "$opener" "$current"
    """

    public static func arguments(pid: Int32, current: String, staged: String, work: String,
                                 log: String, waitLimit: Int = waitLimit, opener: String = "/usr/bin/open") -> [String] {
        ["-c", source, String(pid), current, staged, work, log, String(waitLimit), opener]
    }
}
