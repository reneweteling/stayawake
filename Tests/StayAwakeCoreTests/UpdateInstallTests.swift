import XCTest
@testable import StayAwakeCore

final class UpdateInstallTests: XCTestCase {
    // MARK: - Stage timeouts

    func testEveryStageHasALimit() {
        for stage in UpdateStage.allCases { XCTAssertGreaterThan(stage.timeLimit, 0) }
        XCTAssertLessThanOrEqual(UpdateStage.restoreSleep.timeLimit, 60)
        XCTAssertLessThan(UpdateStage.restart.timeLimit, TimeInterval(SwapScript.waitLimit))
    }

    func testTimeoutPassesTheValueThrough() async throws {
        let value = try await withUpdateTimeout(.verify, seconds: 5) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testTimeoutPassesTheErrorThrough() async {
        struct Boom: Error {}
        do {
            _ = try await withUpdateTimeout(.download, seconds: 5) { () async throws -> Int in throw Boom() }
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }

    /// The 1.5.x hang: work that ignores cancellation must not hold the caller.
    func testTimeoutReturnsEvenWhenTheWorkIgnoresCancellation() async {
        let start = Date()
        do {
            _ = try await withUpdateTimeout(.restoreSleep, seconds: 0.2) { () async throws -> Int in
                usleep(2_000_000)
                return 1
            }
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? UpdateTimeout, UpdateTimeout(stage: .restoreSleep, seconds: 0.2))
            XCTAssertEqual(error.localizedDescription, "Restoring sleep took longer than 0 s")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    // MARK: - Swap script

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SwapScriptTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private struct Layout {
        let current, staged, work, log, opened: URL
    }

    private func layout() throws -> Layout {
        let fm = FileManager.default
        let current = dir.appendingPathComponent("Applications/StayAwake.app")
        let work = dir.appendingPathComponent("work")
        let staged = work.appendingPathComponent("StayAwake.app")
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        try "old".write(to: current.appendingPathComponent("version"), atomically: true, encoding: .utf8)
        try "new".write(to: staged.appendingPathComponent("version"), atomically: true, encoding: .utf8)
        return Layout(current: current, staged: staged, work: work,
                      log: dir.appendingPathComponent("events.jsonl"), opened: dir.appendingPathComponent("opened"))
    }

    /// Records what would be opened instead of launching anything.
    private func opener() throws -> String {
        let script = dir.appendingPathComponent("opener.sh")
        try "#!/bin/sh\necho \"$1\" > \"\(dir.path)/opened\"\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    @discardableResult
    private func runScript(pid: Int32, _ l: Layout, waitLimit: Int = 5) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = SwapScript.arguments(pid: pid, current: l.current.path, staged: l.staged.path,
                                                 work: l.work.path, log: l.log.path, waitLimit: waitLimit,
                                                 opener: try opener())
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func version(_ app: URL) -> String? {
        try? String(contentsOf: app.appendingPathComponent("version"), encoding: .utf8)
    }

    private func logLines(_ l: Layout) -> [[String: String]] {
        let text = (try? String(contentsOf: l.log, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String]
        }
    }

    func testSwapsOnceTheAppHasQuit() throws {
        let l = try layout()
        let quitter = Process()
        quitter.executableURL = URL(fileURLWithPath: "/bin/sleep")
        quitter.arguments = ["0.5"]
        try quitter.run()
        XCTAssertEqual(try runScript(pid: quitter.processIdentifier, l), 0)
        XCTAssertEqual(version(l.current), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: l.work.path))
        XCTAssertEqual(try String(contentsOf: l.opened, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), l.current.path)
        let backups = try FileManager.default.contentsOfDirectory(atPath: l.current.deletingLastPathComponent().path)
        XCTAssertEqual(backups, ["StayAwake.app"])
        XCTAssertEqual(logLines(l).last?["event"], "update_swapped")
    }

    func testGivesUpLoudlyWhenTheAppNeverQuits() throws {
        let l = try layout()
        let stuck = Process()
        stuck.executableURL = URL(fileURLWithPath: "/bin/sleep")
        stuck.arguments = ["30"]
        try stuck.run()
        defer { stuck.terminate() }
        XCTAssertEqual(try runScript(pid: stuck.processIdentifier, l, waitLimit: 1), 1)
        XCTAssertEqual(version(l.current), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: l.work.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: l.opened.path), "must not start a second copy")
        let last = logLines(l).last
        XCTAssertEqual(last?["event"], "update_failed")
        XCTAssertEqual(last?["message"], "Update failed: StayAwake did not quit within 1 s, nothing was replaced")
        XCTAssertNotNil(last?["ts"])
    }

    func testPutsTheOldAppBackWhenTheNewOneCannotMove() throws {
        let l = try layout()
        try FileManager.default.removeItem(at: l.staged)
        XCTAssertEqual(try runScript(pid: 999_999, l), 1)
        XCTAssertEqual(version(l.current), "old")
        XCTAssertTrue(FileManager.default.fileExists(atPath: l.opened.path), "the old app starts again")
        XCTAssertEqual(logLines(l).last?["event"], "update_failed")
    }
}
