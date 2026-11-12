import AppKit
import Foundation
import IOKit
import IOKit.ps

/// Turns system changes into one callback, so the engine evaluates right
/// away on a power source, lid, thermal, network or wake event instead of
/// waiting for the next tick. Every callback only says "look again".
@MainActor
final class SystemEvents {
    private let onEvent: (String) -> Void
    private var lidPort: IONotificationPortRef?
    private var lidNotifier: io_object_t = 0
    private var powerSource: CFRunLoopSource?

    init(onEvent: @escaping (String) -> Void) {
        self.onEvent = onEvent
    }

    func start(network: NetworkWatcher) {
        let me = Unmanaged.passUnretained(self).toOpaque()

        // Power source: AC or battery, charge state, percent.
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let events = Unmanaged<SystemEvents>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { events.onEvent("power") } }
        }, me)?.takeRetainedValue() {
            powerSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        // Lid: general interest messages from the root power domain.
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        if service != 0 {
            lidPort = IONotificationPortCreate(kIOMainPortDefault)
            if let lidPort {
                IONotificationPortSetDispatchQueue(lidPort, .main)
                IOServiceAddInterestNotification(lidPort, service, kIOGeneralInterest, { ctx, _, _, _ in
                    guard let ctx else { return }
                    let events = Unmanaged<SystemEvents>.fromOpaque(ctx).takeUnretainedValue()
                    MainActor.assumeIsolated { events.onEvent("lid") }
                }, me, &lidNotifier)
            }
            IOObjectRelease(service)
        }

        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent("thermal") }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent("wake") }
        }
        network.onChange = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onEvent("network") } }
        }
    }
}
