import Foundation
import Sentry

/// Crash reports through Sentry, switched off in Settings, General. Events
/// carry the app version and rule names, never sensor data or paths.
/// The DSN stays empty until the StayAwake Sentry project exists; with an
/// empty DSN nothing is sent.
enum Telemetry {
    private static let dsn = ""
    private static var started = false

    @MainActor
    static func startIfEnabled() {
        // A bare binary from `swift build` has no bundle; only the packaged app reports.
        guard Bundle.main.bundleIdentifier != nil, !dsn.isEmpty else { return }
        let enabled = AppSettings.shared.crashReports
        if enabled, !started {
            SentrySDK.start { options in
                options.dsn = dsn
                options.releaseName = "stayawake@\(appVersion)"
                options.sendDefaultPii = false
                options.tracesSampleRate = 0
                options.beforeSend = { event in
                    if let message = event.message?.formatted {
                        event.message = SentryMessage(formatted: scrub(message))
                    }
                    event.exceptions?.forEach { $0.value = scrub($0.value) }
                    return event
                }
            }
            started = true
        } else if !enabled, started {
            SentrySDK.close()
            started = false
        }
    }

    static func scrub(_ text: String) -> String {
        text.replacingOccurrences(of: #"(/Users|/Volumes|/private|~)/[^\s'"]+"#, with: "<path>", options: .regularExpression)
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
