import AppKit
import SwiftUI
import StayAwakeCore

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            GeneralTab(settings: settings, model: model).tabItem { Label("General", systemImage: "gearshape") }
            SafetyTab(settings: settings).tabItem { Label("Safety", systemImage: "thermometer.medium") }
            ScheduleTab(settings: settings).tabItem { Label("Schedule", systemImage: "calendar") }
            NotificationsTab(settings: settings).tabItem { Label("Notifications", systemImage: "bell") }
            AdvancedTab(settings: settings, model: model).tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
            AboutTab(model: model).tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 520)
        .padding(12)
    }
}

// MARK: - Small building blocks

/// A stepper whose label shows the value, bound to a `Config` field.
private struct ValueStepper<V: Strideable & Comparable>: View where V.Stride: Comparable {
    let label: String
    @Binding var value: V
    let range: ClosedRange<V>
    var step: V.Stride = 1
    var unit = ""
    var format: (V) -> String = { "\($0)" }

    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            HStack {
                Text(label)
                Spacer()
                Text("\(format(value))\(unit.isEmpty ? "" : " " + unit)").foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

private func formatTemp(_ v: Double) -> String { String(Int(v)) }

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Toggle("Open StayAwake at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) }))
            Toggle("Start armed after launch", isOn: $settings.startArmed)
            Picker("Default \"Arm for\"", selection: $settings.config.armDefault) {
                ForEach(ArmDuration.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .onChange(of: settings.config.armDefault) { _, new in if !model.isArmed { model.armDuration = new } }
            Picker("Menu bar readout", selection: $settings.menuBarReadout) {
                Text("None").tag(MenuBarReadout.none)
                Text("Temperature").tag(MenuBarReadout.temperature)
                Text("Battery").tag(MenuBarReadout.battery)
                Text("Temperature and battery").tag(MenuBarReadout.both)
            }
            .onChange(of: settings.menuBarReadout) { _, _ in model.refreshDisplay() }
            Picker("Temperature unit", selection: $settings.temperatureUnit) {
                Text("Celsius").tag(TemperatureUnit.celsius)
                Text("Fahrenheit").tag(TemperatureUnit.fahrenheit)
            }
            .onChange(of: settings.temperatureUnit) { _, _ in model.refreshDisplay() }
            Picker("After a trip", selection: $settings.config.afterTrip) {
                Text("Stay off until I re-arm").tag(AfterTrip.stayOff)
                Text("Re-arm on wake when all rules are clear").tag(AfterTrip.rearmOnWake)
            }
            Toggle("Clear a leftover SleepDisabled on launch", isOn: $settings.clearLeftoverOnLaunch)
            Toggle("Send crash reports", isOn: $settings.crashReports)
                .onChange(of: settings.crashReports) { _, _ in Telemetry.startIfEnabled() }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Safety

private struct SafetyTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("CPU temperature") {
                Toggle("Enabled", isOn: $settings.config.cpuEnabled)
                if settings.config.cpuEnabled {
                    ValueStepper(label: "Limit", value: $settings.config.cpuLimit, range: 60...100, unit: "°C", format: formatTemp)
                    ValueStepper(label: "Sustain", value: $settings.config.cpuSustainSeconds, range: 0...120, step: 5, unit: "s")
                    ValueStepper(label: "Clears at limit minus", value: $settings.config.cpuClearMargin, range: 2...20, unit: "°C", format: formatTemp)
                }
            }
            Section("GPU temperature") {
                Toggle("Enabled", isOn: $settings.config.gpuEnabled)
                if settings.config.gpuEnabled {
                    ValueStepper(label: "Limit", value: $settings.config.gpuLimit, range: 60...100, unit: "°C", format: formatTemp)
                    ValueStepper(label: "Sustain", value: $settings.config.gpuSustainSeconds, range: 0...120, step: 5, unit: "s")
                    ValueStepper(label: "Clears at limit minus", value: $settings.config.gpuClearMargin, range: 2...20, unit: "°C", format: formatTemp)
                }
            }
            Section("Battery temperature") {
                Toggle("Enabled", isOn: $settings.config.batteryTempEnabled)
                if settings.config.batteryTempEnabled {
                    ValueStepper(label: "Limit", value: $settings.config.batteryTempLimit, range: 30...50, unit: "°C", format: formatTemp)
                    ValueStepper(label: "Sustain", value: $settings.config.batteryTempSustainSeconds, range: 0...120, step: 5, unit: "s")
                    ValueStepper(label: "Clears at limit minus", value: $settings.config.batteryTempClearMargin, range: 1...10, unit: "°C", format: formatTemp)
                }
            }
            Section("Thermal pressure") {
                Toggle("Enabled", isOn: $settings.config.thermalEnabled)
                if settings.config.thermalEnabled {
                    Picker("Trips at", selection: $settings.config.thermalLimit) {
                        Text("Fair").tag(ThermalLevel.fair)
                        Text("Serious").tag(ThermalLevel.serious)
                        Text("Critical").tag(ThermalLevel.critical)
                    }
                }
            }
            Section("Battery floor") {
                Toggle("Enabled", isOn: $settings.config.floorEnabled)
                if settings.config.floorEnabled {
                    ValueStepper(label: "Stops below", value: $settings.config.floorPercent, range: 5...60, unit: "%")
                    Text("Clears when charging or 10 points higher.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Lid closed on battery") {
                Toggle("Enabled", isOn: $settings.config.lidEnabled)
                if settings.config.lidEnabled {
                    ValueStepper(label: "Limit", value: $settings.config.lidMinutes, range: 10...480, step: 10, unit: "min")
                }
            }
            Section("Idle (lid closed)") {
                Toggle("Enabled", isOn: $settings.config.idleEnabled)
                if settings.config.idleEnabled {
                    ValueStepper(label: "CPU below", value: $settings.config.idleCpuPercent, range: 2...50, unit: "%")
                    ValueStepper(label: "For", value: $settings.config.idleMinutes, range: 5...120, step: 5, unit: "min")
                }
            }
            Section("Watched process") {
                Toggle("Enabled", isOn: $settings.config.watchedEnabled)
                if settings.config.watchedEnabled {
                    WatchedNamesField(settings: settings)
                    ValueStepper(label: "None running for", value: $settings.config.watchedMinutes, range: 5...240, step: 5, unit: "min")
                    Text("The process check arrives in a later release. Until then this rule counts as not running.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("No network") {
                Toggle("Enabled", isOn: $settings.config.networkEnabled)
                if settings.config.networkEnabled {
                    ValueStepper(label: "No route for", value: $settings.config.networkMinutes, range: 2...120, unit: "min")
                }
            }
            Section("Hard time cap") {
                Toggle("Enabled", isOn: $settings.config.capEnabled)
                if settings.config.capEnabled {
                    ValueStepper(label: "Held for", value: $settings.config.capHours, range: 1...24, unit: "h")
                }
            }
            Section("Sensor failure") {
                ValueStepper(label: "No valid reading for", value: $settings.config.sensorFailureSeconds, range: 30...300, step: 10, unit: "s")
                Text("Always on. Unknown heat is treated as hot.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Limits are in °C. Changes apply at once.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Keeps the text as typed; the config only receives the cleaned list.
private struct WatchedNamesField: View {
    @ObservedObject var settings: AppSettings
    @State private var text: String

    init(settings: AppSettings) {
        self.settings = settings
        _text = State(initialValue: settings.config.watchedNames.joined(separator: ", "))
    }

    var body: some View {
        TextField("Names, comma separated", text: $text)
            .onChange(of: text) { _, new in settings.config.watchedNames = new.split(separator: ",").map { String($0) } }
    }
}

// MARK: - Schedule

private let weekdayOrder = [1, 2, 3, 4, 5, 6, 0]
private let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

private struct ScheduleTab: View {
    @ObservedObject var settings: AppSettings
    @State private var draft: Schedule
    @State private var problem: String?

    init(settings: AppSettings) {
        self.settings = settings
        _draft = State(initialValue: settings.config.schedule.normalized())
    }

    var body: some View {
        Form {
            Section {
                Toggle("Use schedule", isOn: Binding(get: { draft.enabled }, set: { draft.enabled = $0; commit() }))
                Text("Off means always allowed. Times follow this Mac's time zone. An overnight run is two windows on two days.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if draft.enabled {
                ForEach(weekdayOrder, id: \.self) { day in
                    Section(weekdayNames[day]) { dayEditor(day) }
                }
            }
            if let problem {
                Section { Text(problem).foregroundStyle(.red).font(.callout) }
            }
        }
        .formStyle(.grouped)
    }

    private func commit() {
        for (i, windows) in draft.days.enumerated() {
            for w in windows where w.end <= w.start {
                problem = "\(weekdayNames[i]): the end must be after the start. Not saved yet."
                return
            }
        }
        problem = nil
        settings.config.schedule = draft
        draft = settings.config.schedule
    }

    private func dayEditor(_ day: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if draft.days[day].isEmpty {
                Text("No window. Holding is not allowed on this day.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(draft.days[day].indices, id: \.self) { i in
                HStack {
                    TimeField(minutes: windowBinding(day, i, \.start), isEnd: false)
                    Text("to")
                    TimeField(minutes: windowBinding(day, i, \.end), isEnd: true)
                    Spacer()
                    Button { draft.days[day].remove(at: i); commit() } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                Button("Add window") { addWindow(day) }
                    .disabled(draft.days[day].count >= Schedule.maxWindowsPerDay || nextFreeStart(day) == nil)
                Menu("Copy to…") {
                    ForEach(weekdayOrder.filter { $0 != day }, id: \.self) { other in
                        Button(weekdayNames[other]) { copy(day, to: [other]) }
                    }
                    Divider()
                    Button("Monday to Friday") { copy(day, to: [1, 2, 3, 4, 5]) }
                    Button("All other days") { copy(day, to: Array(0..<7)) }
                }
                .fixedSize()
            }
        }
    }

    private func windowBinding(_ day: Int, _ i: Int, _ key: WritableKeyPath<TimeWindow, Int>) -> Binding<Int> {
        Binding(
            get: { i < draft.days[day].count ? draft.days[day][i][keyPath: key] : 0 },
            set: { value in
                guard i < draft.days[day].count else { return }
                draft.days[day][i][keyPath: key] = value
                commit()
            })
    }

    private func nextFreeStart(_ day: Int) -> Int? {
        let last = draft.days[day].map(\.end).max() ?? 7 * 60 - 60
        let start = last + 60
        return start + 60 <= 1440 ? start : nil
    }

    private func addWindow(_ day: Int) {
        guard let start = nextFreeStart(day) else { return }
        draft.days[day].append(TimeWindow(start: start, end: start + 60))
        commit()
    }

    private func copy(_ day: Int, to targets: [Int]) {
        for t in targets where t != day { draft.days[t] = draft.days[day] }
        commit()
    }
}

/// Hours and minutes in 5 minute steps. An end can also be 24:00.
private struct TimeField: View {
    @Binding var minutes: Int
    let isEnd: Bool

    private var hour: Binding<Int> {
        Binding(get: { minutes / 60 }, set: { h in minutes = h * 60 + (h == 24 ? 0 : (minutes % 60)) })
    }
    private var minute: Binding<Int> {
        Binding(get: { minutes >= 1440 ? 0 : minutes % 60 }, set: { m in minutes = (minutes / 60) * 60 + m })
    }

    var body: some View {
        HStack(spacing: 2) {
            Picker("Hour", selection: hour) {
                ForEach(0..<(isEnd ? 25 : 24), id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
            }
            .labelsHidden().frame(width: 62)
            Text(":")
            Picker("Minute", selection: minute) {
                ForEach(Array(stride(from: 0, to: 60, by: Schedule.stepMinutes)), id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
            }
            .labelsHidden().frame(width: 62).disabled(minutes >= 1440)
        }
    }
}

// MARK: - Notifications

private struct NotificationsTab: View {
    @ObservedObject var settings: AppSettings
    private let sounds = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]

    var body: some View {
        Form {
            Toggle("Notify when a rule trips", isOn: $settings.config.notifyOnTrip)
            Toggle("Alert when unplugged while armed", isOn: $settings.config.alertOnUnplug)
            Toggle("Notify when armed or disarmed by hand", isOn: $settings.config.notifyOnManualArm)
            optionalStepper("Heads-up before a trip", value: $settings.config.headsUpMinutes, on: 5, range: 1...30, unit: "min")
            Picker("Sound on trip", selection: $settings.tripSound) {
                Text("Off").tag("")
                ForEach(sounds, id: \.self) { Text($0).tag($0) }
            }
            .onChange(of: settings.tripSound) { _, name in if !name.isEmpty { NSSound(named: NSSound.Name(name))?.play() } }
            optionalStepper("Keep the event log", value: $settings.config.logRetentionDays, on: 30, range: 7...365, unit: "days")
            optionalStepper("Sample sensors into the log every", value: $settings.config.sampleMinutes, on: 5, range: 1...60, unit: "min")
        }
        .formStyle(.grouped)
    }

    /// A toggle plus a stepper for a value where 0 means off.
    private func optionalStepper(_ label: String, value: Binding<Int>, on: Int, range: ClosedRange<Int>, unit: String) -> some View {
        VStack(alignment: .leading) {
            Toggle(label, isOn: Binding(get: { value.wrappedValue > 0 }, set: { value.wrappedValue = $0 ? on : 0 }))
            if value.wrappedValue > 0 {
                ValueStepper(label: "Value", value: value, range: range, unit: unit)
            }
        }
    }
}

// MARK: - Advanced

private struct AdvancedTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Evaluation") {
                ValueStepper(label: "Interval while holding", value: $settings.config.holdingIntervalSeconds, range: 5...60, step: 5, unit: "s")
                ValueStepper(label: "Interval while off", value: $settings.config.offIntervalSeconds, range: 30...300, step: 30, unit: "s")
                ValueStepper(label: "Lease length", value: $settings.config.leaseSeconds, range: 30...120, step: 10, unit: "s")
                Text("Heartbeat to the backend is fixed at 10 s.").font(.caption).foregroundStyle(.secondary)
                Picker("Prefer sensor", selection: $settings.config.sensorPreference) {
                    Text("Automatic").tag(SensorPreference.automatic)
                    Text("HID thermal").tag(SensorPreference.hid)
                    Text("SMC").tag(SensorPreference.smc)
                    Text("Thermal state only").tag(SensorPreference.thermalStateOnly)
                }
            }
            Section("Backend") {
                LabeledContent("Sleep control", value: model.backend.name)
                LabeledContent("Status", value: model.setupMessage ?? "Ready")
            }
            Section("Tools") {
                HStack {
                    Button("Restore sleep now") { model.restoreSleepNow() }
                    Button("Export log…", action: exportLog)
                    Button("Copy diagnostics", action: copyDiagnostics)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func exportLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "stayawake-events.jsonl"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.copyItem(at: EventLog.url, to: url)
    }

    private func copyDiagnostics() {
        let s = model.snapshot
        let c = settings.config
        let lines = [
            "StayAwake \(Telemetry.appVersion)",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "backend: \(model.backend.name), \(model.setupMessage ?? "ready")",
            "phase: \(model.engine.phase.rawValue), SleepDisabled: \(model.sleepDisabled.map { $0 ? "1" : "0" } ?? "unknown")",
            "CPU \(s.cpuTemperature.map { String(format: "%.1f", $0) } ?? "n/a"), GPU \(s.gpuTemperature.map { String(format: "%.1f", $0) } ?? "n/a"), battery temp \(s.batteryTemperature.map { String(format: "%.1f", $0) } ?? "n/a")",
            "battery \(s.batteryPercent.map(String.init) ?? "n/a")%, \(s.powerSource.rawValue), lid \(s.lidClosed ? "closed" : "open"), thermal \(s.thermal.rawValue)",
            "limits: CPU \(c.cpuLimit), GPU \(c.gpuLimit), battery \(c.batteryTempLimit), floor \(c.floorPercent)%, sensor \(c.sensorPreference.rawValue)",
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

// MARK: - About

private struct AboutTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            Text("StayAwake").font(.largeTitle.bold())
            Text("Stay awake. Then stop.").foregroundStyle(.secondary)
            Text("Version \(Telemetry.appVersion)").font(.callout)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("If sleep ever stays disabled, run this in a terminal:").font(.callout)
                HStack {
                    Text(BackendFactory.manualRestoreCommand).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(BackendFactory.manualRestoreCommand, forType: .string)
                    }
                }
                Text("Or run StayAwake --restore.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Event log: ~/Library/Logs/StayAwake/events.jsonl").font(.caption).foregroundStyle(.secondary)
            Link("reneweteling.github.io/stayawake", destination: URL(string: "https://reneweteling.github.io/stayawake/")!)
            Spacer()
            Text("© 2026 Felobo B.V.").font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
}
