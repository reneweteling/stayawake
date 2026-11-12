export const faq: [string, string][] = [
  ['What does it actually do?', 'It runs pmset -a disablesleep 1 for you, through a small root helper, so a closed MacBook on battery keeps running. It turns sleep back on by itself when a safety rule trips, when the app stops talking to the helper, and on every boot.'],
  ['What if the app crashes while it holds?', 'The helper owns a lease that the app renews every 10 seconds. When the heartbeats stop, the lease runs out within 60 seconds and the helper restores sleep. After a reboot the helper restores sleep before anything else.'],
  ['What can the helper run?', 'Exactly two commands, /usr/bin/pmset -a disablesleep 1 and 0, from a fixed list. No shell, no strings from the app, and only a client signed with the StayAwake Developer ID may connect.'],
  ['Which rules release it?', 'CPU, GPU and battery temperature, macOS thermal pressure, a battery floor, allowed hours per weekday, lid closed on battery for too long, idle, no network, a hard time cap and unreadable sensors. Unreadable sensors count as a trip.'],
  ['Why not the App Store?', 'It needs a root helper, so it ships as a signed and notarized app on GitHub releases.'],
  ['What does it send?', 'Crash reports through Sentry with the app version and rule names, and nothing else. No sensor data leaves the Mac. You can switch crash reports off in Settings.'],
  ['What does it cost?', 'Free for noncommercial use under PolyForm Noncommercial 1.0.0. The source is on GitHub.'],
];
