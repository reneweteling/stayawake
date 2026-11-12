import Foundation

/// The only two things the privileged helper may ever run. Input from the
/// outside is a case of this enum, never a string that becomes an argument.
public enum PmsetCommand: String, CaseIterable, Codable, Sendable {
    case disableSleepOn
    case disableSleepOff

    public static let executable = "/usr/bin/pmset"

    /// Read-only `pmset -g`, which the helper uses to report SleepDisabled.
    /// Not a case on purpose: it changes nothing and is never chosen by input.
    public static let readSettingsArgv = [executable, "-g"]

    public var arguments: [String] {
        switch self {
        case .disableSleepOn: return ["-a", "disablesleep", "1"]
        case .disableSleepOff: return ["-a", "disablesleep", "0"]
        }
    }

    /// Full argv including argv[0].
    public var argv: [String] { [PmsetCommand.executable] + arguments }

    /// Full argv for the dev backend: `sudo -n` plus the fixed pmset argv.
    /// `-n` makes sudo fail instead of asking for a password.
    public var sudoArgv: [String] { ["/usr/bin/sudo", "-n"] + argv }

    /// The sudoers rule text for this command, as scripts/dev-sudoers.sh installs it.
    public func sudoersRule(user: String) -> String {
        "\(user) ALL=(root) NOPASSWD: \(argv.joined(separator: " "))"
    }

    /// Maps an argv back to a command; anything else is nil.
    public init?(argv: [String]) {
        guard let match = PmsetCommand.allCases.first(where: { $0.argv == argv }) else { return nil }
        self = match
    }
}
