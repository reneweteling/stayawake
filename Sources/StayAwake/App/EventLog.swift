import AppKit
import Foundation
import StayAwakeCore

/// One line of ~/Library/Logs/StayAwake/events.jsonl.
struct LogEntry: Codable {
    var ts: String
    var event: String
    var rule: String?
    var value: Double?
    var limit: Double?
    var message: String?
    var battery: Int?
    var cpu: Double?
    var gpu: Double?
    var batteryTemp: Double?
    var thermal: String?
    var lidClosed: Bool?
    var powerSource: String?
    var backend: String?
}

/// Append-only JSON lines. Writes go through one serial queue and never
/// throw into the caller: a full disk must not stop a trip from releasing.
final class EventLog: @unchecked Sendable {
    static let shared = EventLog()

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/StayAwake/events.jsonl")
    }

    private let queue = DispatchQueue(label: "stayawake.eventlog")
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static func stamp(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    static func entry(_ event: String, snapshot: Snapshot?, backend: String? = nil) -> LogEntry {
        var e = LogEntry(ts: stamp(), event: event)
        if let s = snapshot {
            e.battery = s.batteryPercent
            e.cpu = s.cpuTemperature
            e.gpu = s.gpuTemperature
            e.batteryTemp = s.batteryTemperature
            e.thermal = s.thermal.rawValue
            e.lidClosed = s.lidClosed
            e.powerSource = s.powerSource.rawValue
        }
        e.backend = backend
        return e
    }

    /// `retentionDays == 0` means the user switched the log off.
    func append(_ entry: LogEntry, retentionDays: Int) {
        guard retentionDays > 0 else { return }
        queue.async { [encoder] in
            guard var data = try? encoder.encode(entry) else { return }
            data.append(0x0A)
            let url = Self.url
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    /// Drops lines older than the retention. Lines are in time order.
    func prune(retentionDays: Int) {
        queue.async {
            let url = Self.url
            guard retentionDays > 0, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            let cutoff = Self.stamp(Date().addingTimeInterval(-Double(retentionDays) * 86400))
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            // The ts field is ISO 8601 in UTC, so string order is time order.
            let kept = lines.filter { line in
                guard let r = line.range(of: "\"ts\":\"") else { return true }
                return String(line[r.upperBound...].prefix(24)) >= cutoff
            }
            if kept.count != lines.count {
                try? (kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")).write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Opens the log in TextEdit, or reveals it in Finder when that fails.
    @MainActor
    static func open() {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
