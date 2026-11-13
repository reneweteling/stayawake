import AppKit
import Foundation
import StayAwakeCore

/// Looks for a newer release on GitHub and installs it, ported from
/// TidyDrive: a check on launch, then at most once a day (the timer looks
/// every 3 hours), an About row with the states, and an optional automatic
/// install that waits until StayAwake is off and nobody is looking at it.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published private(set) var latestVersion: String?
    @Published private(set) var releaseURL: URL?
    @Published private(set) var isUpdateAvailable = false
    @Published private(set) var isChecking = false
    @Published private(set) var lastCheckError: String?
    @Published private(set) var lastCheckedAt: Date?
    /// "Downloading", "Checking", "Restoring sleep", "Restarting" while an update installs.
    @Published private(set) var installStep: String?
    @Published private(set) var installError: String?
    private(set) var asset: ReleaseInfo.Asset?

    /// Installs new releases on its own when StayAwake is off and idle.
    var autoInstall: Bool {
        get { UserDefaults.standard.object(forKey: "autoInstallUpdates") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoInstallUpdates"); objectWillChange.send() }
    }
    /// Asked before an automatic install: armed, tripped or a window open.
    var isBusy: () -> Bool = { true }
    /// Disarms and releases sleep before the bundles swap. Throws to stop the update.
    var prepareForInstall: @MainActor () async throws -> Void = {}
    /// Any failed install: logs `update_failed` with the reason and makes
    /// arming work again.
    var installFailed: @MainActor (String) -> Void = { _ in }

    var canInstall: Bool { asset != nil && SelfUpdater.canUpdateInPlace }
    var currentVersion: String { Telemetry.appVersion }

    private let lastCheckKey = "lastUpdateCheck"
    private var checkedThisProcess = false
    private var timer: Timer?

    /// Launch check plus the periodic one.
    func start() {
        Task { await checkIfNeeded() }
        timer?.invalidate()
        let timer = Timer(timeInterval: UpdatePolicy.timerInterval, repeats: true) { _ in
            Task { @MainActor in
                await UpdateChecker.shared.checkIfNeeded()
                await UpdateChecker.shared.installPendingIfIdle()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func checkIfNeeded() async {
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Double
        guard UpdatePolicy.shouldCheck(checkedThisProcess: checkedThisProcess,
                                       lastCheck: last.map { Date(timeIntervalSince1970: $0) }, now: Date()) else { return }
        await performCheck()
    }

    func forceCheck() async { await performCheck() }

    func openReleasesPage() {
        NSWorkspace.shared.open(releaseURL ?? UpdatePolicy.releasesPageURL)
    }

    /// Called when StayAwake goes quiet (disarmed, popover or window closed).
    func installPendingIfIdle() async {
        guard isUpdateAvailable, autoInstall, canInstall, installStep == nil, installError == nil, !isBusy() else { return }
        await install()
    }

    func install() async {
        guard let asset, let latestVersion, installStep == nil else { return }
        installError = nil
        installStep = UpdateStage.download.title
        do {
            try await SelfUpdater.install(asset: asset, version: latestVersion, progress: { stage in
                Task { @MainActor in
                    let checker = UpdateChecker.shared
                    if checker.installStep != nil { checker.installStep = stage.title }
                }
            }, beforeSwap: prepareForInstall)
        } catch {
            let step = installStep ?? "Installing"
            installStep = nil
            let reason = "\(step): \(error.localizedDescription)"
            installError = reason
            installFailed(reason)
        }
    }

    private func performCheck() async {
        guard !isChecking, installStep == nil else { return }
        isChecking = true
        lastCheckError = nil
        defer { isChecking = false }
        checkedThisProcess = true

        var request = URLRequest(url: UpdatePolicy.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await SelfUpdater.session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                lastCheckError = "GitHub returned \(http.statusCode)"
                return
            }
            let release = try ReleaseInfo.parse(data)
            switch UpdatePolicy.verdict(currentVersion: currentVersion, release: release) {
            case .upToDate(let latest):
                latestVersion = latest
                releaseURL = release.htmlURL
                asset = nil
                isUpdateAvailable = false
            case .available(let version, let page, let download):
                latestVersion = version
                releaseURL = page
                asset = download
                isUpdateAvailable = true
            }
            lastCheckedAt = Date()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
            if isUpdateAvailable { await installPendingIfIdle() }
        } catch {
            lastCheckError = error.localizedDescription
        }
    }
}
