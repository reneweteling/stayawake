import AppKit
import CryptoKit
import Foundation
import Security
import StayAwakeCore

/// Installs a new release over the running app, the TidyDrive way: download
/// the DMG, copy the app out of it, check it, then swap the bundles once
/// StayAwake has quit and start it again.
///
/// Checks, all before anything is replaced: the DMG matches GitHub's SHA-256,
/// the app passes a strict signature check (nested helper included) against
/// StayAwake's identifier and team, the helper inside is signed the same way,
/// Gatekeeper accepts it (so it is notarized) and its version is the one the
/// release promised. Then `beforeSwap` runs: the model disarms and releases
/// sleep, and the update stops if that fails.
enum SelfUpdater {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The bundle that would be replaced, or why updating in place is not possible.
    static func installedBundle() throws -> URL {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app", Bundle.main.bundleIdentifier == HelperIdentity.appIdentifier else {
            throw Failure(message: "Not running from the StayAwake app bundle")
        }
        if bundle.path.contains("/AppTranslocation/") {
            throw Failure(message: "Move StayAwake to Applications first")
        }
        let parent = bundle.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent) else {
            throw Failure(message: "No write access to \(parent). Download the update by hand.")
        }
        return bundle
    }

    /// Only a copy signed by StayAwake's team updates itself; dev builds don't.
    static var canUpdateInPlace: Bool {
        guard (try? installedBundle()) != nil else { return false }
        return satisfies(Bundle.main.bundleURL, requirement: appRequirement, nested: false)
    }

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["User-Agent": UpdatePolicy.userAgent]
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    static func install(asset: ReleaseInfo.Asset, version: String,
                        progress: @escaping @Sendable (UpdateStage) -> Void,
                        beforeSwap: @escaping @MainActor () async throws -> Void) async throws {
        let current = try installedBundle()
        guard canUpdateInPlace else {
            throw Failure(message: "This copy of StayAwake is not signed by its developer, so it cannot check an update")
        }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("StayAwakeUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var handedOver = false
        defer { if !handedOver { try? FileManager.default.removeItem(at: work) } }

        progress(.download)
        let dmg = work.appendingPathComponent("StayAwake.dmg")
        try await withUpdateTimeout(.download) {
            var request = URLRequest(url: asset.downloadURL)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            let (downloaded, response) = try await session.download(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw Failure(message: "Download failed with \(http.statusCode)")
            }
            try FileManager.default.moveItem(at: downloaded, to: dmg)
        }

        progress(.verify)
        let staged = try await withUpdateTimeout(.verify) {
            try await Task.detached { try stage(dmg: dmg, in: work, asset: asset, version: version) }.value
        }

        progress(.restoreSleep)
        // Never swap with sleep disabled: the model disarms, releases and
        // throws when it cannot confirm that sleep is back.
        try await withUpdateTimeout(.restoreSleep) { try await beforeSwap() }

        progress(.restart)
        // A detached shell waits for this process to quit, swaps the bundles
        // (putting the old one back if the move fails) and opens the new one.
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/sh")
        swap.arguments = SwapScript.arguments(pid: ProcessInfo.processInfo.processIdentifier, current: current.path,
                                              staged: staged.path, work: work.path, log: EventLog.url.path)
        try swap.run()
        handedOver = true
        await MainActor.run { quitForUpdate() }
    }

    /// Quits so the shell can swap the bundles. Sleep is already restored.
    ///
    /// `NSApp.terminate` must not run inside a main-actor task: the app
    /// delegate answers `.terminateLater` from another main-actor task, which
    /// cannot start while this one blocks inside terminate. 1.5.0 and 1.5.1
    /// hung there forever. So: terminate from the run loop, let the delegate
    /// answer `.terminateNow` for an update, and exit hard if it still lives.
    @MainActor static func quitForUpdate() {
        isQuittingForUpdate = true
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + UpdateStage.restart.timeLimit) {
            NSLog("StayAwake: did not quit for the update in time, exiting")
            exit(0)
        }
    }

    /// Set once sleep is confirmed restored and the swap shell is running.
    @MainActor static var isQuittingForUpdate = false

    /// Checksum, mount, copy the app out, verify. Runs off the main thread.
    static func stage(dmg: URL, in work: URL, asset: ReleaseInfo.Asset, version: String) throws -> URL {
        if let expected = asset.sha256 {
            let data = try Data(contentsOf: dmg, options: .mappedIfSafe)
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw Failure(message: "The download does not match the release checksum") }
        }
        let mount = work.appendingPathComponent("mnt")
        let attach = run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen",
                                              "-mountpoint", mount.path])
        guard attach.status == 0 else { throw Failure(message: "Could not open the update: \(attach.output)") }
        defer { run("/usr/bin/hdiutil", ["detach", mount.path, "-force"], timeout: 30) }
        guard let app = try FileManager.default.contentsOfDirectory(atPath: mount.path).first(where: { $0.hasSuffix(".app") }) else {
            throw Failure(message: "The update holds no app")
        }
        let staged = work.appendingPathComponent(app)
        let copy = run("/usr/bin/ditto", ["\(mount.path)/\(app)", staged.path])
        guard copy.status == 0 else { throw Failure(message: "Could not copy the update: \(copy.output)") }
        try verify(staged, expectedVersion: version)
        return staged
    }

    // MARK: - Verification

    static var appRequirement: String { HelperIdentity.requirement(identifier: HelperIdentity.appIdentifier, relaxed: false) }

    /// Strict signature of the whole bundle and its helper, Gatekeeper, and
    /// the version the release named. No downgrades.
    static func verify(_ app: URL, expectedVersion: String) throws {
        guard satisfies(app, requirement: appRequirement, nested: true) else {
            throw Failure(message: "The update is not signed by StayAwake's developer")
        }
        let helper = app.appendingPathComponent("Contents/MacOS/StayAwakeHelper")
        guard satisfies(helper, requirement: HelperIdentity.helperRequirement(relaxed: false), nested: false) else {
            throw Failure(message: "The helper in the update is not signed by StayAwake's developer")
        }
        let check = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard check.status == 0 else { throw Failure(message: "The update's signature is not valid") }
        let gatekeeper = run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
        guard gatekeeper.status == 0 else { throw Failure(message: "Gatekeeper rejects the update") }

        let info = Bundle(url: app)?.infoDictionary
        guard info?["CFBundleIdentifier"] as? String == HelperIdentity.appIdentifier else {
            throw Failure(message: "The update is a different app")
        }
        let newVersion = info?["CFBundleShortVersionString"] as? String ?? ""
        guard UpdatePolicy.compare(newVersion, expectedVersion) == .orderedSame else {
            throw Failure(message: "The update says it is \(newVersion), the release says \(expectedVersion)")
        }
        guard UpdatePolicy.compare(newVersion, Telemetry.appVersion) == .orderedDescending else {
            throw Failure(message: "The update is not newer than this version")
        }
    }

    /// Security framework check against a requirement string. `nested` also
    /// checks every nested executable and framework.
    static func satisfies(_ url: URL, requirement text: String, nested: Bool) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        var flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        if nested { flags.insert(SecCSFlags(rawValue: kSecCSCheckNestedCode)) }
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// Runs a tool and returns its status and output. Kills it after
    /// `timeout` seconds so a stuck hdiutil or spctl cannot hang the update.
    @discardableResult
    static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval = 120) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        var data = Data()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global().async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            reader.leave()
        }
        let name = (tool as NSString).lastPathComponent
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 3) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            _ = reader.wait(timeout: .now() + 2)
            return (-1, "\(name) did not finish within \(Int(timeout)) s")
        }
        _ = reader.wait(timeout: .now() + 5)
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
