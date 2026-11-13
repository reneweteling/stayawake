import Foundation

/// The decision behind "Turn on again when plugged in after a low-battery stop".
/// Pure on purpose: the rule engine passes in what it knows and acts on the answer.
public enum AutoRearm {
    /// True when a stop caused by the battery floor should turn on again now.
    /// It needs the setting, the Mac on AC, a charge back at or above the floor, and
    /// every other rule clear. Any other stop reason (heat, sensors, time cap,
    /// schedule, network and so on) never turns on by itself here.
    public static func shouldRearm(
        enabled: Bool, lastTrip: RuleID?, powerSource: PowerSource, batteryPercent: Int?,
        floorEnabled: Bool, floorPercent: Int, otherRulesClear: Bool
    ) -> Bool {
        guard enabled, lastTrip == .batteryFloor, powerSource == .ac, otherRulesClear else { return false }
        guard floorEnabled else { return true }
        guard let percent = batteryPercent else { return false }
        return percent >= floorPercent
    }
}
