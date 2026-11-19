import AppKit
import Combine
import Foundation
import StayAwakeCore

/// Owns the engine loop. Reads the sensors, asks `RuleEngine` what to do,
/// and carries out the answer through the `PmsetBackend`.
///
/// Everything that changes state runs through `enqueue`, one at a time, so a
/// slow sensor read or a slow `sudo` can never interleave with an arm, a
/// disarm or the next evaluation.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let settings = AppSettings.shared
    let backend: PmsetBackend
    private let hub = SensorHub()
    private let sensorQueue = DispatchQueue(label: "stayawake.sensors")
    private let backendQueue = DispatchQueue(label: "stayawake.backend")
    private let log = EventLog.shared

    // What the views read.
    @Published private(set) var engine = EngineState()
    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var decision: Decision?
    @Published private(set) var status = MenuBarStatus(kind: .off, symbol: "moon.zzz", tooltip: "StayAwake: off")
    /// SleepDisabled from `pmset -g`. The banner wording depends on it, so it follows every reading.
    @Published private(set) var sleepDisabled: Bool? {
        didSet { if sleepDisabled != oldValue { updateTroubleText() } }
    }
    @Published private(set) var availability: BackendAvailability
    @Published private(set) var heldFor: TimeInterval?
    @Published private(set) var timerLeft: TimeInterval?
    @Published private(set) var trippedAt: Date?
    @Published private(set) var message: String?
    @Published private(set) var lastEvent = "No events yet"
    @Published private(set) var unplugBanner = false
    /// One line about the helper for Settings, Advanced (version, lease).
    @Published private(set) var helperInfo: String?
    /// Set while sleep control keeps failing and the app retries. Clears
    /// itself once the system is where the app wants it.
    @Published private(set) var helperTrouble: String?
    @Published var armDuration: ArmDuration
    @Published var popoverOpen = false {
        didSet {
            guard popoverOpen != oldValue else { return }
            if !popoverOpen { unplugBanner = false }
            reschedule()
            if popoverOpen { requestEvaluation("popover") }
        }
    }

    /// Set by the AppDelegate: open the popover by itself (unplug alert).
    var showPopover: (() -> Void)?

    // Loop plumbing.
    private var tail: Task<Void, Never> = Task {}
    private var evaluationQueued = false
    private var evaluationTimer: Timer?
    private var heartbeatTimer: Timer?
    private var kickTask: Task<Void, Never>?
    private var pendingWake = false
    private var events: SystemEvents?
    private var activity: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    // Bookkeeping.
    private var heldByUs = false
    private var headsUpSent = Set<RuleID>()
    private var lastSampleLog: TimeInterval?
    private var lastSnapshotForEvents: Snapshot?
    private var helperReplaced = false
    /// Backoff and escalation while hold or release calls fail.
    private var retry = HelperRetry()
    /// A hold was asked for since the last confirmed release: a SleepDisabled
    /// still on outside Holding is ours to clear.
    private var releaseOwed = false
    /// A heartbeat failed: the lease may run out, so hold again.
    private var leaseLost = false
    /// Set once an update is about to replace the app: no more arming.
    private var updating = false

    private init() {
        backend = BackendFactory.make()
        availability = backend.availability()
        armDuration = AppSettings.shared.config.armDefault
        status = makeStatus(now: makeNow())
    }

    // MARK: - Derived

    var isArmed: Bool { engine.phase == .waiting || engine.phase == .holding }
    var config: Config { settings.config.clamped() }
    var setupNeed: SetupNeed? {
        if case .setupRequired(let need) = availability { return need }
        return nil
    }
    var setupMessage: String? { setupNeed?.title }
    var helper: HelperManaging? { backend as? HelperManaging }

    // MARK: - Start and stop

    func start() {
        guard !started else { return }
        started = true
        // A6: the loop must keep its timers with the lid closed and the
        // display asleep. This option stops App Nap but allows system sleep.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Evaluating safety rules")
        NotificationManager.shared.setUp()
        let events = SystemEvents { [weak self] reason in
            guard let self else { return }
            if reason == "wake" { self.pendingWake = true }
            self.kick(reason)
        }
        events.start(network: hub.network)
        self.events = events

        // Setting changes (a lowered limit, a new schedule) apply at once.
        settings.$config.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.kick("settings") } }
        }.store(in: &cancellables)

        log.prune(retentionDays: config.logRetentionDays)
        record(LogEntry(ts: EventLog.stamp(), event: "launch", backend: backend.name))

        enqueue { [self] in
            let reading = await sample()
            sleepDisabled = reading.pmset?.sleepDisabled
            snapshot = reading.snapshot
            await refreshAvailability()
            await checkHelperVersion()
            // An update went ahead without confirming that sleep was back.
            let owedFromUpdate = restoreSleepAfterUpdate
            if owedFromUpdate {
                releaseOwed = true
                // The helper restart above may have released already.
                sleepDisabled = await readSleepDisabled() ?? sleepDisabled
                if sleepDisabled == false { restoreSleepAfterUpdate = false }
            }
            // Q11: StayAwake owns the flag, so a leftover one is cleared.
            // If this fails, reconcile keeps trying while releaseOwed is set.
            if settings.clearLeftoverOnLaunch || owedFromUpdate, sleepDisabled == true, availability == .ready {
                let error = await backendCall { [backend] in try backend.release(reason: "leftover") }
                if let error {
                    note("Could not clear a leftover SleepDisabled: \(error)", event: "leftover_failed")
                } else {
                    note("Cleared a leftover SleepDisabled on launch", event: "leftover_cleared")
                }
            }
            updateStatus()
            reschedule()
            if settings.startArmed { await performArm(manual: false) }
        }
        requestEvaluation("launch")
    }

    /// Quit disarms first: release, wait for the answer (2 s), then exit.
    func prepareToQuit() async {
        let work = enqueue { [self] in
            let (state, action) = RuleEngine.disarm(engine)
            engine = state
            if action == .release || heldByUs {
                _ = await backendCall { [backend] in try backend.release(reason: "quit") }
                heldByUs = false
            }
            record(entry("quit"))
            stopHeartbeat()
        }
        // Not a task group: that waits for `work` even after the 2 s are up.
        _ = try? await withUpdateTimeout(.restart, seconds: 2) { await work.value }
    }

    /// The updater calls this right before it swaps the app. Disarms, stops
    /// the heartbeat and releases, then reads `pmset -g` to confirm sleep is
    /// back. It never stops the update (see `UpdateSleepCheck`): with sleep
    /// still off it retries once on a fresh connection, then lets the update
    /// go ahead and leaves a note so the new version releases on launch.
    func prepareForUpdate() async throws {
        await enqueue { [self] in
            updating = true
            engine = RuleEngine.disarm(engine).state
            headsUpSent = []
            stopHeartbeat()
            // Whatever happens below, SleepDisabled is ours to clear now.
            releaseOwed = true
            var attempts = 0
            var lastError: String?
            while true {
                if attempts > 0 { try? await Task.sleep(for: .seconds(1)) }
                attempts += 1
                lastError = nil
                if availability == .ready || heldByUs || sleepDisabled != false {
                    lastError = await releaseOnce(reason: "update")
                }
                let reading = await sample()
                sleepDisabled = reading.pmset?.sleepDisabled
                switch UpdateSleepCheck.verdict(sleepDisabled: sleepDisabled, released: lastError == nil, attempts: attempts) {
                case .proceed:
                    restoreSleepAfterUpdate = false
                    if let lastError {
                        note("Installing an update, sleep is enabled (the helper call failed: \(lastError))", event: "update_install")
                    } else {
                        note("Installing an update, sleep restored", event: "update_install")
                    }
                case .retry:
                    continue
                case .proceedRestoreOnLaunch:
                    restoreSleepAfterUpdate = true
                    let why = lastError ?? (sleepDisabled == true ? "SleepDisabled is still on" : "pmset could not be read")
                    note("Installing an update, sleep not restored yet (\(why)). The helper lets it go within a minute and the new version restores it on launch.",
                         event: "update_install_unrestored")
                }
                break
            }
            await finishEvaluation(reason: "update")
        }.value
    }

    /// Set when an update went ahead with sleep possibly still disabled. The
    /// next launch (the new version) releases, whatever the leftover setting
    /// says, and clears it once `pmset -g` shows sleep enabled.
    private var restoreSleepAfterUpdate: Bool {
        get { UserDefaults.standard.bool(forKey: "restoreSleepAfterUpdate") }
        set { UserDefaults.standard.set(newValue, forKey: "restoreSleepAfterUpdate") }
    }

    /// Any failed install: log the reason and make arming work again. Queued,
    /// so it lands after a `prepareForUpdate` that is still running.
    func updateDidFail(reason: String) {
        enqueue { [self] in
            updating = false
            note("Update failed: \(reason)", event: "update_failed")
            updateStatus()
        }
    }

    // MARK: - User actions

    func arm() { enqueue { [self] in await performArm(manual: true) } }

    func disarm() {
        enqueue { [self] in
            let (state, action) = RuleEngine.disarm(engine)
            engine = state
            message = nil
            headsUpSent = []
            if action == .release { await releaseWithRetries(reason: "disarm") }
            note("Disarmed at \(clockNow())", event: "disarm")
            if config.notifyOnManualArm { NotificationManager.shared.notifyArmed("Disarmed. Normal sleep is back.") }
            await finishEvaluation(reason: "disarm")
            requestEvaluation("disarm")
        }
    }

    /// The tripped icon was seen: back to Off.
    func acknowledge() {
        enqueue { [self] in
            guard engine.phase == .tripped else { return }
            engine = RuleEngine.acknowledge(engine)
            trippedAt = nil
            updateStatus()
        }
    }

    /// Restore sleep now. Works without the rule engine: it disarms and
    /// releases whatever the phase says.
    func restoreSleepNow() {
        enqueue { [self] in
            engine = RuleEngine.disarm(engine).state
            headsUpSent = []
            // Whatever set it, the user wants it off: keep trying until it is.
            releaseOwed = true
            if let error = await releaseOnce(reason: "restore") {
                message = "Could not restore sleep: \(error). Run \(BackendFactory.manualRestoreCommand) in a terminal."
                note("Restore sleep failed: \(error)", event: "restore_failed")
            } else {
                message = nil
                note("Sleep restored by hand at \(clockNow())", event: "restore")
            }
            await finishEvaluation(reason: "restore")
            requestEvaluation("restore")
        }
    }

    func dismissMessage() { message = nil }

    // MARK: - Helper setup

    /// The button next to the setup text: register, or open Login Items.
    func performSetupAction() {
        guard let need = setupNeed else { return }
        switch need.action {
        case .register: enqueue { [self] in await registerHelper() }
        case .openLoginItems: helper?.openApprovalSettings()
        case .none: break
        }
    }

    func openLoginItems() { helper?.openApprovalSettings() }

    /// Settings, Advanced: unregister and register again. Releases first.
    func reinstallHelper() {
        enqueue { [self] in
            guard let helper else { return }
            await disarmForHelperChange()
            let error = await backendCall { try helper.reinstall() }
            await refreshAvailability()
            if let error {
                message = "Could not reinstall the helper: \(error)"
                note("Helper reinstall failed: \(error)", event: "helper_reinstall_failed")
            } else {
                note(availability == .ready ? "Helper reinstalled" : "Helper reinstalled, waiting for approval", event: "helper_reinstalled")
            }
            await refreshHelperInfo()
            updateStatus()
        }
    }

    /// Settings, Advanced: release, then unregister. Stops if the release fails,
    /// so removing the helper never leaves sleep disabled.
    func removeHelper() {
        enqueue { [self] in
            guard let helper else { return }
            if availability == .ready {
                engine = RuleEngine.disarm(engine).state
                headsUpSent = []
                if let error = await releaseOnce(reason: "remove") {
                    message = "Helper not removed, sleep could not be restored first: \(error)"
                    note("Helper removal stopped: \(error)", event: "helper_remove_failed")
                    await finishEvaluation(reason: "remove")
                    return
                }
            }
            let error = await backendCall { try helper.remove() }
            await refreshAvailability()
            if let error {
                message = "Could not remove the helper: \(error)"
                note("Helper removal failed: \(error)", event: "helper_remove_failed")
            } else {
                note("Helper removed. Sleep control is off until you set it up again.", event: "helper_removed")
            }
            helperInfo = nil
            await finishEvaluation(reason: "remove")
        }
    }

    /// Settings, Advanced opens: ask the helper how it is doing.
    func refreshHelperInfoNow() { enqueue { [self] in await refreshHelperInfo() } }

    private func registerHelper() async {
        guard let helper else { return }
        let error = await backendCall { try helper.register() }
        await refreshAvailability()
        if let error {
            message = "Could not set up sleep control: \(error)"
            note("Helper registration failed: \(error)", event: "helper_register_failed")
        } else if availability != .ready {
            note("Helper installed, waiting for approval in Login Items", event: "helper_registered")
        }
        updateStatus()
    }

    /// Launch check: the running helper must be the one in this bundle (same
    /// version and same binary). If not, ask it to restart, once per launch.
    /// Never unregisters an approved helper: that would cost the approval.
    private func checkHelperVersion() async {
        guard let helper, availability == .ready, !helperReplaced else { return }
        let (verdict, status, registration) = await withCheckedContinuation { c in
            backendQueue.async { c.resume(returning: (helper.versionVerdict(), helper.helperStatus(), helper.registration())) }
        }
        let step = HelperRepair.forVersion(verdict, registration: registration,
                                           helperCanRestart: status?.canRestart == true)
        if step != .nothing {
            helperReplaced = true
            await runRepair(step, why: { if case .replace(let why) = verdict { return why }; return "" }(),
                            event: "helper_updated")
        }
        await refreshHelperInfo()
    }

    /// Carries out a `HelperRepair` step and logs what happened.
    private func runRepair(_ step: HelperRepair.Step, why: String, event: String) async {
        guard let helper else { return }
        switch step {
        case .nothing, .awaitApproval:
            return
        case .keepUntilReboot(let why):
            note("Helper differs (\(why)) and is too old to restart itself; it keeps working and is replaced at the next restart",
                 event: "helper_update_deferred")
            return
        case .restartHelper:
            // The helper releases before it exits; the app holds again if armed.
            if let error = await backendCall({ try helper.restartForUpdate() }) {
                note("Helper restart failed (\(why)): \(error)", event: "\(event)_failed")
            } else {
                note("Helper restarted with this version (\(why))", event: event)
            }
        case .register:
            if let error = await backendCall({ try helper.register() }) {
                note("Registering the helper failed: \(error)", event: "\(event)_failed")
            } else {
                note("Helper registered (\(why))", event: event)
            }
        case .reinstall:
            if let error = await backendCall({ try helper.reinstall() }) {
                note("Reinstalling the helper failed: \(error)", event: "\(event)_failed")
            } else {
                note("Helper reinstalled (\(why))", event: event)
            }
        }
        await refreshAvailability(force: true)
        if availability != .ready {
            // The popover shows the setup card with Open Login Items.
            note("Sleep control waits for approval in Login Items", event: "helper_needs_approval")
        }
    }

    private func refreshHelperInfo() async {
        guard let helper else { helperInfo = nil; return }
        let status: HelperStatus? = await withCheckedContinuation { c in
            backendQueue.async { c.resume(returning: helper.helperStatus()) }
        }
        guard let status else {
            helperInfo = availability == .ready ? "Helper not answering" : nil
            return
        }
        var parts = ["Helper \(status.version)"]
        if status.held, let left = status.leaseRemaining {
            parts.append("holding, lease \(Int(left)) s")
        } else {
            parts.append("not holding")
        }
        if let error = status.lastError { parts.append("last error: \(error)") }
        helperInfo = parts.joined(separator: ", ")
    }

    /// Before the helper goes away: disarm and release while it can still answer.
    private func disarmForHelperChange() async {
        guard availability == .ready else { return }
        engine = RuleEngine.disarm(engine).state
        headsUpSent = []
        _ = await releaseOnce(reason: "helper-change")
        await finishEvaluation(reason: "helper-change")
    }

    // MARK: - Arm

    private func performArm(manual: Bool) async {
        guard !updating else { return }
        message = nil
        // A new arm starts fresh: first try right away, a new give-up clock.
        if retry.inTrouble { retry.succeeded(); updateTroubleText() }
        await refreshAvailability()
        // First arm installs the helper. Whatever is still missing after
        // that shows once in the popover, with its button.
        if setupNeed?.action == .register { await registerHelper() }
        if setupNeed != nil {
            updateStatus()
            return
        }
        NotificationManager.shared.requestAuthorizationIfNeeded()
        let reading = await sample()
        let snap = reading.snapshot
        snapshot = snap
        sleepDisabled = reading.pmset?.sleepDisabled
        let result = RuleEngine.arm(snap, config: config, state: engine, now: makeNow(), duration: armDuration)
        if case .refused(let trips) = result.outcome {
            message = "Not armed. " + trips.map(\.message).joined(separator: ". ")
            var e = entry("arm_refused", snapshot: snap)
            e.rule = trips.first?.rule.rawValue
            e.message = trips.map(\.message).joined(separator: "; ")
            record(e)
            lastEvent = "Arm refused at \(clockNow()): \(trips.first?.message ?? "a rule is failing")"
            updateStatus()
            return
        }
        trippedAt = nil
        headsUpSent = []
        lastSampleLog = nil
        var e = entry("arm", snapshot: snap)
        e.message = armDuration.rawValue
        record(e)
        switch result.outcome {
        case .waitingForSchedule(let opens):
            lastEvent = "Armed at \(clockNow()), waiting for \(opens.map { Readout.opensAt($0, now: Date(), in: .current) } ?? "a schedule window")"
        default:
            lastEvent = "Armed at \(clockNow())"
        }
        if manual, config.notifyOnManualArm { NotificationManager.shared.notifyArmed("Armed. This Mac stays awake with the lid closed.") }
        await apply(result.decision, snapshot: snap, reason: "arm")
    }

    // MARK: - Evaluation loop

    func requestEvaluation(_ reason: String) {
        guard !evaluationQueued else { return }
        evaluationQueued = true
        enqueue { [self] in
            evaluationQueued = false
            await runEvaluation(reason: reason)
        }
    }

    /// Events can arrive in bursts (a lid close sends several messages), so
    /// they are folded into one evaluation shortly after.
    private func kick(_ reason: String) {
        kickTask?.cancel()
        kickTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.requestEvaluation(reason)
        }
    }

    private func runEvaluation(reason: String) async {
        let wake = pendingWake
        pendingWake = false
        let reading = await sample(didWake: wake)
        let snap = reading.snapshot
        snapshot = snap
        sleepDisabled = reading.pmset?.sleepDisabled
        await refreshAvailability()

        if engine.phase == .tripped, let at = trippedAt, Date().timeIntervalSince(at) > 12 * 3600 {
            engine = RuleEngine.acknowledge(engine)
            trippedAt = nil
        }
        let d = RuleEngine.evaluate(snap, config: config, state: engine, now: makeNow())
        await apply(d, snapshot: snap, reason: reason)
    }

    /// Carries out a decision: hold or release, trip handling, alerts, logs.
    private func apply(_ d: Decision, snapshot snap: Snapshot, reason: String) async {
        let before = engine.phase
        engine = d.state
        decision = d
        let cfg = config

        if d.timerEnded {
            note("Timer ended at \(clockNow())", event: "timer_ended", snapshot: snap)
        }

        switch d.action {
        case .hold:
            releaseOwed = true
            if let error = await backendCall({ [backend, lease = cfg.leaseSeconds] in try backend.hold(leaseSeconds: lease, reason: "rules") }) {
                // Stay armed and keep trying (see `reconcile`). The popover says
                // so, and gives up with a reason only after a long time.
                helperFailed(error, event: "hold_failed", snapshot: snap)
                await refreshAvailability(force: true)
            } else {
                heldByUs = true
                leaseLost = false
                helperWorks()
                if before != .holding { note("Holding since \(clockNow())", event: "hold", snapshot: snap) }
            }
            sleepDisabled = await readSleepDisabled() ?? sleepDisabled
        case .release:
            await releaseWithRetries(reason: d.trip != nil ? "trip" : (d.timerEnded ? "timer" : "rules"))
            if d.trip != nil || d.timerEnded { scheduleSleepNowFallback() }
            sleepDisabled = await readSleepDisabled() ?? sleepDisabled
        case .none:
            break
        }

        if let trip = d.trip { handleTrip(trip, snapshot: snap, config: cfg) }
        if d.alerts.contains(.unpluggedWhileHolding) { handleUnplug(snapshot: snap) }
        if d.alerts.contains(.rearmedOnPower) { handleRearmedOnPower(snapshot: snap, config: cfg) }

        if d.action == .none { await reconcile(snapshot: snap, config: cfg) }

        if engine.phase != .tripped { trippedAt = nil }
        handleHeadsUp(d, config: cfg)
        logSample(snap, config: cfg)
        await finishEvaluation(reason: reason)
    }

    private func finishEvaluation(reason: String) async {
        if engine.phase == .holding { startHeartbeat() } else { stopHeartbeat() }
        if engine.phase != .holding { headsUpSent = []; lastSampleLog = nil }
        updateStatus()
        reschedule()
    }

    // MARK: - Trip, alerts, heads-up

    private func handleTrip(_ trip: TripInfo, snapshot snap: Snapshot, config cfg: Config) {
        trippedAt = Date()
        var e = entry("trip", snapshot: snap)
        e.rule = trip.rule.rawValue
        e.value = trip.value
        e.limit = trip.limit
        e.message = trip.message
        record(e)
        lastEvent = "\(clockNow()) · \(trip.message)"
        if cfg.notifyOnTrip { NotificationManager.shared.notifyTrip(trip, at: Date(), timeZone: .current) }
        NotificationManager.shared.playTripSound(named: settings.tripSound)
    }

    private func handleRearmedOnPower(snapshot snap: Snapshot, config cfg: Config) {
        let level = snap.batteryPercent.map { ", battery \($0)%" } ?? ""
        let text = "Turned on again: plugged in\(level)"
        record(entry("auto_rearm", snapshot: snap).with(message: text))
        lastEvent = "\(clockNow()) · \(text)"
        if cfg.notifyOnTrip { NotificationManager.shared.notifyArmed(text) }
    }

    private func handleUnplug(snapshot snap: Snapshot) {
        record(entry("unplugged", snapshot: snap))
        lastEvent = "\(clockNow()) · Unplugged while armed"
        unplugBanner = true
        NotificationManager.shared.notifyUnplugged()
        showPopover?()
    }

    private func handleHeadsUp(_ d: Decision, config cfg: Config) {
        guard cfg.headsUpMinutes > 0, engine.phase == .holding else { return }
        let threshold = Double(cfg.headsUpMinutes) * 60
        let due = d.margins.filter { m in
            guard m.rule != .sensorFailure else { return false }
            return (m.seconds.map { $0 > 0 && $0 <= threshold } ?? false) || d.warnings.contains(m.rule)
        }
        let dueRules = Set(due.map(\.rule))
        headsUpSent = headsUpSent.intersection(dueRules)
        for m in due where !headsUpSent.contains(m.rule) {
            headsUpSent.insert(m.rule)
            NotificationManager.shared.notifyHeadsUp(m)
            var e = entry("heads_up", snapshot: snapshot)
            e.rule = m.rule.rawValue
            e.message = Readout.marginLine(m)
            record(e)
        }
    }

    private func logSample(_ snap: Snapshot, config cfg: Config) {
        guard engine.phase == .holding, cfg.sampleMinutes > 0 else { return }
        let m = makeNow().monotonic
        if let last = lastSampleLog, m - last < Double(cfg.sampleMinutes) * 60 { return }
        lastSampleLog = m
        record(entry("sample", snapshot: snap))
    }

    // MARK: - Backend calls

    /// Runs a blocking backend call off the main thread. Returns the error text, or nil.
    private func backendCall(_ work: @escaping @Sendable () throws -> Void) async -> String? {
        await withCheckedContinuation { continuation in
            backendQueue.async {
                do { try work(); continuation.resume(returning: nil) }
                catch { continuation.resume(returning: String(describing: error)) }
            }
        }
    }

    private func releaseOnce(reason: String) async -> String? {
        let error = await backendCall { [backend] in try backend.release(reason: reason) }
        if error == nil { heldByUs = false }
        return error
    }

    /// Spec section 5: ask for disablesleep 0, retry 3 times, 1 s apart.
    /// After that `reconcile` keeps trying with backoff until it works.
    private func releaseWithRetries(reason: String) async {
        var last: String?
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
            last = await releaseOnce(reason: reason)
            if last == nil {
                helperWorks()
                return
            }
        }
        let first = !retry.inTrouble
        helperFailed(last ?? "unknown", event: "release_failed", snapshot: snapshot)
        if first {
            NotificationManager.shared.notifyArmed("StayAwake could not restore sleep yet and keeps trying. If it stays, run \(BackendFactory.manualRestoreCommand) in a terminal.")
        }
    }

    // MARK: - Self-healing

    /// Makes the system match what the app wants, every evaluation: holding
    /// means SleepDisabled on, anything else means off (when StayAwake set
    /// it). Failed calls back off (1, 2, 5, then every 15 s) without end;
    /// after a few in a row the helper is restarted or registered again. An armed Mac
    /// that cannot be held for 5 minutes stops with the reason.
    private func reconcile(snapshot snap: Snapshot, config cfg: Config) async {
        guard !updating else { return }
        let now = makeNow().monotonic
        if engine.phase == .holding, retry.inTrouble, retry.shouldGiveUpHolding(now: now) {
            let why = retry.lastError ?? "unknown error"
            engine = RuleEngine.disarm(engine).state
            headsUpSent = []
            leaseLost = false
            let minutes = Int(HelperRetry.giveUpHoldingAfter / 60)
            message = "Could not keep this Mac awake: sleep control failed for \(minutes) min (\(why)). StayAwake is off."
            note("Stopped, sleep control failed for \(minutes) min: \(why)", event: "hold_gave_up", snapshot: snap)
        }
        let need = SleepReconcile.need(phase: engine.phase, sleepDisabled: sleepDisabled, leaseLost: leaseLost,
                                       releaseOwed: releaseOwed, clearLeftover: settings.clearLeftoverOnLaunch)
        switch need {
        case .nothing:
            if engine.phase != .holding, sleepDisabled == false {
                releaseOwed = false
                if restoreSleepAfterUpdate { restoreSleepAfterUpdate = false }
            }
            helperWorks()
        case .hold:
            guard retry.mayAttempt(now: now) else { break }
            await reregisterIfDue(now: now)
            let why = leaseLost ? "lease was lost" : "SleepDisabled was off"
            if let error = await backendCall({ [backend, lease = cfg.leaseSeconds] in try backend.hold(leaseSeconds: lease, reason: "reassert") }) {
                helperFailed(error, event: "reassert_failed", snapshot: snap)
            } else {
                heldByUs = true
                leaseLost = false
                helperWorks()
                note("Holding again (\(why))", event: "reassert", snapshot: snap)
            }
            sleepDisabled = await readSleepDisabled() ?? sleepDisabled
        case .release:
            guard retry.mayAttempt(now: now) else { break }
            await reregisterIfDue(now: now)
            if let error = await releaseOnce(reason: "reconcile") {
                helperFailed(error, event: "release_failed", snapshot: snap)
            } else {
                releaseOwed = false
                helperWorks()
                note("Sleep restored, SleepDisabled was still on while not holding", event: "release_reconciled", snapshot: snap)
            }
            sleepDisabled = await readSleepDisabled() ?? sleepDisabled
        }
        updateTroubleText()
    }

    private func helperFailed(_ error: String, event: String, snapshot snap: Snapshot) {
        retry.failed(error, now: makeNow().monotonic)
        Telemetry.capture(error, kind: event, context: reportContext())
        // Log the first few and then every 20th, so a long outage does not flood the log.
        if retry.failures <= 5 || retry.failures % 20 == 0 {
            var e = entry(event, snapshot: snap).with(message: error)
            e.value = Double(retry.failures)
            record(e)
        }
        lastEvent = "\(clockNow()) · Sleep control failed, retrying: \(error)"
        updateTroubleText()
    }

    private func helperWorks() {
        if retry.inTrouble {
            note("Sleep control works again after \(retry.failures) failed attempt\(retry.failures == 1 ? "" : "s")", event: "helper_recovered")
        }
        retry.succeeded()
        updateTroubleText()
    }

    private func updateTroubleText() {
        helperTrouble = SleepControlText.banner(phase: engine.phase, sleepDisabled: sleepDisabled,
                                                failures: retry.failures, lastError: retry.lastError,
                                                manualRestore: BackendFactory.manualRestoreCommand)
    }

    /// After a few failures in a row: restart or register the helper, at most
    /// every 10 min. An approved helper is never unregistered here.
    private func reregisterIfDue(now: TimeInterval) async {
        guard let helper, retry.shouldReregister(now: now) else { return }
        retry.didReregister(now: now)
        let (registration, status) = await withCheckedContinuation { c in
            backendQueue.async { c.resume(returning: (helper.registration(), helper.helperStatus())) }
        }
        let step = HelperRepair.forFailures(registration: registration, helperStatus: status)
        await runRepair(step, why: "\(retry.failures) failures", event: "helper_reregistered")
    }

    /// SleepDisabled right after a hold or release, so the popover never
    /// shows a value from before the call.
    private func readSleepDisabled() async -> Bool? {
        await withCheckedContinuation { c in
            sensorQueue.async { c.resume(returning: ReadOnlyCommand.pmsetG().map(PmsetParser.parse)?.sleepDisabled) }
        }
    }

    private func heartbeatFailed(_ error: String) {
        guard engine.phase == .holding else { return }
        if !leaseLost { NSLog("StayAwake: heartbeat failed, holding again: %@", error) }
        leaseLost = true
        requestEvaluation("heartbeat-failed")
    }

    /// A1: with the lid closed the Mac should sleep by itself once the hold is
    /// gone. If this process is still running 10 s later with the lid still
    /// closed, ask for sleep as the user (no root needed).
    private func scheduleSleepNowFallback() {
        guard snapshot.lidClosed else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self else { return }
            let closed = IORegistryReader.lidClosed() ?? false
            guard closed, self.engine.phase != .holding else { return }
            self.record(self.entry("sleepnow_fallback").with(message: "Still awake 10 s after release with the lid closed"))
            DispatchQueue.global().async { SleepNow.run() }
        }
    }

    private func refreshAvailability(force: Bool = false) async {
        let value: BackendAvailability = await withCheckedContinuation { c in
            backendQueue.async { [backend] in c.resume(returning: backend.availability()) }
        }
        guard availability != value else { return }
        let wasSetup = setupNeed != nil
        availability = value
        // The approval in System Settings happened outside the app.
        if wasSetup, value == .ready, backend is HelperManaging {
            note("Helper ready", event: "helper_ready")
            await checkHelperVersion()
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        guard heartbeatTimer == nil else { return }
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendHeartbeat() }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
        sendHeartbeat()
    }

    private func sendHeartbeat() {
        let lease = config.leaseSeconds
        backendQueue.async { [weak self, backend] in
            guard let error = backend.heartbeat(leaseSeconds: lease) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.heartbeatFailed(error) } }
        }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    // MARK: - Scheduling

    private func reschedule() {
        evaluationTimer?.invalidate()
        let cfg = config
        var seconds = Double(popoverOpen ? 5 : (engine.phase == .holding ? cfg.holdingIntervalSeconds : cfg.offIntervalSeconds))
        // A pending retry comes sooner.
        if let wait = retry.wait(now: makeNow().monotonic) { seconds = min(seconds, max(1, wait)) }
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestEvaluation("timer") }
        }
        RunLoop.main.add(timer, forMode: .common)
        evaluationTimer = timer
    }

    // MARK: - Helpers

    @discardableResult
    private func enqueue(_ op: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task { @MainActor in
            await previous.value
            await op()
        }
        tail = task
        return task
    }

    private func sample(didWake: Bool = false) async -> SensorReading {
        let preference = settings.config.sensorPreference
        return await withCheckedContinuation { continuation in
            sensorQueue.async { [hub] in
                hub.preference = preference
                hub.didWake = didWake
                hub.waitForNetworkOnce()
                continuation.resume(returning: hub.read())
            }
        }
    }

    private func makeNow() -> Moment {
        Moment(monotonic: Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9, wall: Date(), timeZone: .current)
    }

    private func clockNow() -> String { Readout.clock(Date(), in: .current) }

    private func entry(_ event: String, snapshot snap: Snapshot? = nil) -> LogEntry {
        EventLog.entry(event, snapshot: snap ?? snapshot, backend: nil)
    }

    private func record(_ e: LogEntry) { log.append(e, retentionDays: config.logRetentionDays) }

    private func note(_ text: String, event: String, snapshot snap: Snapshot? = nil) {
        lastEvent = text
        report(text, event: event)
        record(entry(event, snapshot: snap).with(message: text))
    }

    /// Sentry: every logged event becomes a breadcrumb, and the failures
    /// and the "waiting for approval" state also become an event.
    private func report(_ text: String, event: String) {
        Telemetry.breadcrumb(text, category: event)
        let failing = event.hasSuffix("_failed") || ["update_blocked", "update_install_unrestored", "hold_gave_up", "helper_needs_approval"].contains(event)
        if failing { Telemetry.capture(text, kind: event, context: reportContext()) }
    }

    /// What helps to read an error: registration, helper and app version,
    /// pmset state and macOS version. No paths, no sensor readings.
    private func reportContext() -> [String: Any] {
        var info: [String: Any] = [
            "app_version": Telemetry.appVersion,
            "macos": ProcessInfo.processInfo.operatingSystemVersionString,
            "backend": backend.name,
            "phase": String(describing: engine.phase),
            "pmset_sleep_disabled": sleepDisabled.map { $0 ? "on" : "off" } ?? "unknown",
            "failures_in_a_row": retry.failures,
            "updating": updating,
        ]
        if let helper { info["helper_registration"] = String(describing: helper.registration()) }
        info["helper_info"] = helperInfo ?? "none"
        return info
    }

    private func makeStatus(now: Moment) -> MenuBarStatus {
        MenuBarStatus.make(.init(
            phase: engine.phase, setupMessage: setupMessage, snapshot: snapshot, decision: decision,
            lastTrip: engine.lastTrip, trippedAt: trippedAt, heldFor: heldFor, now: now.wall, config: config,
            readout: settings.menuBarReadout, unit: settings.temperatureUnit, timeZone: now.timeZone))
    }

    private func updateStatus() {
        let now = makeNow()
        heldFor = engine.heldSince.map { max(0, now.monotonic - $0) }
        if let d = engine.armDeadlineMonotonic {
            timerLeft = max(0, d - now.monotonic)
        } else if let d = engine.armDeadlineWall {
            timerLeft = max(0, d.timeIntervalSince(now.wall))
        } else {
            timerLeft = nil
        }
        status = makeStatus(now: now)
    }

    /// Re-renders after a display setting changed (unit, readout).
    func refreshDisplay() { updateStatus() }
}

private extension LogEntry {
    func with(message: String) -> LogEntry {
        var copy = self
        copy.message = message
        return copy
    }
}
