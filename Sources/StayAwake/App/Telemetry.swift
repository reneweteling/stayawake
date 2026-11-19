import Foundation
import Sentry

/// Crash and error reports through Sentry. Off when the user switches it off
/// in Settings, General, and off when no DSN is configured.
///
/// The DSN comes from the `SentryDSN` key in Info.plist. A DSN is public, but
/// keeping it there makes it a build setting: build.sh overrides it from the
/// SENTRY_DSN environment variable. An empty value means nothing is sent.
///
/// Events carry versions, helper state and error text with file paths
/// replaced. No IP address, user name, hostname or sensor readings.
enum Telemetry {
    private static var started = false
    private static let lock = NSLock()
    private static var recent: [String: Date] = [:]

    /// The DSN from Info.plist, or nil when it is missing or still a placeholder.
    static var dsn: String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty || value.hasPrefix("$(") ? nil : value
    }

    static var environment: String {
        #if DEBUG
        "debug"
        #else
        "release"
        #endif
    }

    @MainActor
    static func startIfEnabled() {
        // A bare binary from `swift build` has no bundle; only the packaged app reports.
        guard Bundle.main.bundleIdentifier != nil, let dsn else { return }
        let enabled = AppSettings.shared.crashReports
        if enabled, !started {
            SentrySDK.start { options in
                options.dsn = dsn
                options.releaseName = "stayawake@\(appVersion)"
                options.environment = environment
                options.sendDefaultPii = false
                options.tracesSampleRate = 0
                options.maxBreadcrumbs = 100
                options.beforeSend = { event in
                    if let message = event.message?.formatted {
                        event.message = SentryMessage(formatted: scrub(message))
                    }
                    event.exceptions?.forEach { $0.value = scrub($0.value) }
                    // No host name and no user, whatever the SDK filled in.
                    event.serverName = nil
                    event.user = nil
                    return event
                }
                options.beforeBreadcrumb = { crumb in
                    if let text = crumb.message { crumb.message = scrub(text) }
                    return crumb
                }
            }
            SentrySDK.configureScope { scope in
                scope.setTag(value: ProcessInfo.processInfo.operatingSystemVersionString, key: "macos")
                scope.setTag(value: appVersion, key: "app_version")
            }
            lock.lock()
            started = true
            lock.unlock()
        } else if !enabled, started {
            SentrySDK.close()
            lock.lock()
            started = false
            lock.unlock()
        }
    }

    private static var isOn: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    /// A step worth seeing in the trail before an error: helper connect,
    /// invalidation, sleep on and off, update stages.
    static func breadcrumb(_ message: String, category: String, level: SentryLevel = .info) {
        guard isOn else { return }
        let crumb = Breadcrumb(level: level, category: category)
        crumb.message = scrub(message)
        SentrySDK.addBreadcrumb(crumb)
    }

    /// Sends one event for an error the user sees or a helper call that failed.
    /// `kind` groups the events in Sentry. The same kind and text is sent at
    /// most once per 10 minutes, so a retry loop cannot flood the project.
    static func capture(_ text: String, kind: String, context: [String: Any] = [:]) {
        guard isOn else { return }
        let message = scrub(text)
        let key = kind + "|" + message
        lock.lock()
        let now = Date()
        if let last = recent[key], now.timeIntervalSince(last) < 600 { lock.unlock(); return }
        recent[key] = now
        if recent.count > 200 { recent = recent.filter { now.timeIntervalSince($0.value) < 600 } }
        lock.unlock()

        let event = Event(level: .error)
        event.message = SentryMessage(formatted: message)
        event.fingerprint = [kind]
        event.tags = ["error_kind": kind]
        event.extra = context
        SentrySDK.capture(event: event)
    }

    static func scrub(_ text: String) -> String {
        text.replacingOccurrences(of: #"(/Users|/Volumes|/private|~)/[^\s'"]+"#, with: "<path>", options: .regularExpression)
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
