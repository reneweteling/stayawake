import Foundation
import StayAwakeCore

// Stub until M5. The real helper is a launchd daemon that listens on XPC,
// owns the lease and runs the two PmsetCommand argv arrays as root.
// It does nothing today, on purpose: this build never changes power settings.
FileHandle.standardError.write(Data("StayAwakeHelper: not implemented yet\n".utf8))
exit(0)
