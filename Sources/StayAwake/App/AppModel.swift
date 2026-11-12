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
    @Published private(set) var sleepDisabled: Bool?
    @Published private(set) var availability: BackendAvailability
    @Published private(set) var heldFor: TimeInterval?
    @Published private(set) var timerLeft: TimeInterval?
    @Published private(set) var trippedAt: Date?
    @Published private(set) var message: String?
    @Published private(set) var lastEvent = "No events yet"
    @Published private(set) var unplugBanner = false
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

    private init() {
        backend = BackendFactory.make()
        availability = backend.availability()
        armDuration = AppSettings.shared.config.armDefault
        status = makeStatus(now: makeNow())
    }

    // MARK: - Derived

    var isArmed: Bool { engine.phase == .waiting || engine.phase == .holding }
    var config: Config { settings.config.clamped() }
    var setupMessage: String? {
        if case .setupRequired(let text) = availability { return text }
        return nil
    }

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
            // Q11: StayAwake owns the flag, so a leftover one is cleared.
            if settings.clearLeftoverOnLaunch, sleepDisabled == true, availability == .ready {
                let error = await backendCall { [backend] in try backend.release() }
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
                _ = await backendCall { [backend] in try backend.release() }
                heldByUs = false
            }
            record(entry("quit"))
            stopHeartbeat()
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await work.value }
            group.addTask { try? await Task.sleep(for: .seconds(2)) }
            await group.next()
            group.cancelAll()
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
            if action == .release { await releaseWithRetries() }
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
            if let error = await releaseOnce() {
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

    // MARK: - Arm

    private func performArm(manual: Bool) async {
        message = nil
        await refreshAvailability()
        if case .setupRequired(let text) = availability {
            message = text
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
            if let error = await backendCall({ [backend, lease = cfg.leaseSeconds] in try backend.hold(leaseSeconds: lease) }) {
                // Nothing was held, so the engine must not think it is.
                engine = RuleEngine.disarm(engine).state
                message = "Could not keep this Mac awake: \(error)"
                note("Hold failed: \(error)", event: "hold_failed", snapshot: snap)
                await refreshAvailability(force: true)
            } else {
                heldByUs = true
                if before != .holding { note("Holding since \(clockNow())", event: "hold", snapshot: snap) }
            }
        case .release:
            await releaseWithRetries()
            if d.trip != nil || d.timerEnded { scheduleSleepNowFallback() }
        case .none:
            break
        }

        if let trip = d.trip { handleTrip(trip, snapshot: snap, config: cfg) }
        if d.alerts.contains(.unpluggedWhileHolding) { handleUnplug(snapshot: snap) }

        // The UI shows what the system says. If we hold but the system says
        // sleep is allowed (a watchdog fired, a wake), put the hold back.
        if engine.phase == .holding, d.action != .hold, sleepDisabled == false, heldByUs {
            if let error = await backendCall({ [backend, lease = cfg.leaseSeconds] in try backend.hold(leaseSeconds: lease) }) {
                message = "SleepDisabled went off and could not be set again: \(error)"
                note("Reassert failed: \(error)", event: "reassert_failed", snapshot: snap)
            } else {
                note("SleepDisabled was off while holding, set it again", event: "reassert", snapshot: snap)
            }
        }

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

    private func releaseOnce() async -> String? {
        let error = await backendCall { [backend] in try backend.release() }
        if error == nil { heldByUs = false }
        return error
    }

    /// Spec section 5: ask for disablesleep 0, retry 3 times, 1 s apart.
    private func releaseWithRetries() async {
        var last: String?
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
            last = await releaseOnce()
            if last == nil { return }
        }
        let text = "StayAwake could not restore sleep (\(last ?? "unknown")). Run \(BackendFactory.manualRestoreCommand) in a terminal."
        message = text
        record(entry("release_failed", snapshot: snapshot).with(message: text))
        NotificationManager.shared.notifyArmed(text)
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
        if availability != value { availability = value }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        guard heartbeatTimer == nil else { return }
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let lease = self.config.leaseSeconds
                self.backendQueue.async { [backend = self.backend] in backend.heartbeat(leaseSeconds: lease) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
        let lease = config.leaseSeconds
        backendQueue.async { [backend] in backend.heartbeat(leaseSeconds: lease) }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    // MARK: - Scheduling

    private func reschedule() {
        evaluationTimer?.invalidate()
        let cfg = config
        let seconds: Int = popoverOpen ? 5 : (engine.phase == .holding ? cfg.holdingIntervalSeconds : cfg.offIntervalSeconds)
        let timer = Timer(timeInterval: Double(seconds), repeats: false) { [weak self] _ in
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
        record(entry(event, snapshot: snap).with(message: text))
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
