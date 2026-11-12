import AppKit
import Combine
import SwiftUI
import StayAwakeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private let model = AppModel.shared
    private var acknowledgeOnClose = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Telemetry.startIfEnabled()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageLeading
        }
        render(model.status)
        model.$status.receive(on: DispatchQueue.main).sink { [weak self] in self?.render($0) }.store(in: &cancellables)

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let root = PopoverView(model: model, settings: AppSettings.shared,
                               openSettings: { [weak self] in self?.showSettings() },
                               quit: { NSApp.terminate(nil) })
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        model.showPopover = { [weak self] in self?.showPopover() }
        model.start()

        // `open StayAwake.app --args --show settings` for when the icon is hidden behind the notch.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--show"), i + 1 < args.count, args[i + 1] == "settings" { showSettings() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quit disarms first: the model releases sleep and waits up to 2 s.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await model.prepareToQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: Menu bar item

    private func render(_ status: MenuBarStatus) {
        guard let button = statusItem?.button else { return }
        button.image = Self.image(for: status)
        let color: NSColor? = status.tone == .amber ? .systemOrange : (status.tone == .red ? .systemRed : nil)
        var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]
        if let color { attributes[.foregroundColor] = color }
        button.attributedTitle = NSAttributedString(string: status.title.isEmpty ? "" : " " + status.title, attributes: attributes)
        button.toolTip = status.tooltip
        statusItem.length = NSStatusItem.variableLength
    }

    /// Template symbols tint with the menu bar. The warning state draws an amber dot, so it is not a template.
    private static func image(for status: MenuBarStatus) -> NSImage? {
        guard let base = NSImage(systemSymbolName: status.symbol, accessibilityDescription: status.tooltip) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let symbol = base.withSymbolConfiguration(config) ?? base
        guard status.kind == .warning else {
            symbol.isTemplate = true
            return symbol
        }
        let size = symbol.size
        let image = NSImage(size: size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)
            let d: CGFloat = 6
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - d, y: rect.maxY - d, width: d, height: d)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: Popover

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }

    private func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        acknowledgeOnClose = model.engine.phase == .tripped
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        model.popoverOpen = true
    }

    func popoverDidClose(_ notification: Notification) {
        model.popoverOpen = false
        // Seeing the tripped popover is the acknowledgement.
        if acknowledgeOnClose, model.engine.phase == .tripped { model.acknowledge() }
        acknowledgeOnClose = false
    }

    // MARK: Settings window

    private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView(settings: AppSettings.shared, model: model)))
            window.title = "StayAwake Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
