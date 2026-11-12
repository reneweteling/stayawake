import AppKit
import StayAwakeCore

if let code = CommandLineMode.runIfRequested() { exit(code) }

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
