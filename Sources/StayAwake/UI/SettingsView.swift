import AppKit
import SwiftUI
import StayAwakeCore

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            GeneralTab(settings: settings, model: model).tabItem { Label("General", systemImage: "gearshape") }
            ScheduleTab(settings: settings).tabItem { Label("Schedule", systemImage: "calendar") }
            SafetyTab(settings: settings, model: model).tabItem { Label("Safety", systemImage: "thermometer.medium") }
            IdleTab(settings: settings, model: model).tabItem { Label("When Idle", systemImage: "moon.zzz") }
            NotificationsTab(settings: settings).tabItem { Label("Notifications", systemImage: "bell") }
            AdvancedTab(settings: settings, model: model).tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
            AboutView().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 600, height: 580)
    }
}

// MARK: - Building blocks

/// A number with its unit and a stepper, in one Form row. The optional help
/// line shows in gray under the label.
private struct NumberRow<V: Strideable & Comparable>: View where V.Stride: Comparable {
    let label: String
    var help: String?
    @Binding var value: V
    let range: ClosedRange<V>
    var step: V.Stride = 1
    let text: (V) -> String

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Text(text(value)).monospacedDigit()
                Stepper(label, value: $value, in: range, step: step).labelsHidden()
            }
        } label: {
            Text(label)
            if let help { Text(help) }
        }
    }
}

/// A rule's on/off switch: a plain title and a gray line with the live reading.
private struct RuleToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var detailColor: Color = .secondary

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
            Text(detail).foregroundStyle(detailColor)
        }
    }
}

private enum Fmt {
    static func temp(_ celsius: Double, _ unit: TemperatureUnit) -> String {
        "\(Readout.number(unit.convert(celsius))) \(unit.symbol)"
    }

    /// A difference in degrees, so Fahrenheit has no 32 offset.
    static func tempDelta(_ celsius: Double, _ unit: TemperatureUnit) -> String {
        "\(Readout.number(unit == .celsius ? celsius : celsius * 9 / 5)) \(unit.symbol)"
    }

    static func seconds(_ s: Int) -> String {
        if s < 60 { return "\(s) s" }
        return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s"
    }

    static func minutes(_ m: Int) -> String {
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    static func hours(_ h: Int) -> String { h == 1 ? "1 hour" : "\(h) hours" }

    static func heat(_ level: ThermalLevel) -> String {
        switch level {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Critical"
        }
    }
}

private extension Text {
    /// The gray explanation under a row or at the bottom of a section.
    func note() -> some View {
        font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Keeping awake") {
                Picker(selection: $settings.config.armDefault) {
                    ForEach(ArmDuration.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    Text("Keep awake")
                    Text("The choice the menu starts with when you turn StayAwake on.")
                }
                .onChange(of: settings.config.armDefault) { _, new in if !model.isArmed { model.armDuration = new } }
                Picker(selection: $settings.config.afterTrip) {
                    Text("Stay off until I turn it on").tag(AfterTrip.stayOff)
                    Text("Turn on again when the Mac wakes").tag(AfterTrip.rearmOnWake)
                } label: {
                    Text("After StayAwake stops")
                    Text("Turning on again only happens when every limit is fine, and never after the maximum time or a sensor problem.")
                }
            }
            Section("Startup") {
                Toggle("Open StayAwake at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) }))
                Toggle("Turn on StayAwake when it opens", isOn: $settings.startArmed)
                Toggle(isOn: $settings.clearLeftoverOnLaunch) {
                    Text("Repair sleep when StayAwake opens")
                    Text("If StayAwake quit while it was keeping the Mac awake, normal sleep is turned back on.")
                }
            }
            Section("Menu bar") {
                Picker("Show next to the icon", selection: $settings.menuBarReadout) {
                    Text("Nothing").tag(MenuBarReadout.none)
                    Text("Temperature").tag(MenuBarReadout.temperature)
                    Text("Battery").tag(MenuBarReadout.battery)
                    Text("Temperature and battery").tag(MenuBarReadout.both)
                }
                .onChange(of: settings.menuBarReadout) { _, _ in model.refreshDisplay() }
                Picker("Temperatures in", selection: $settings.temperatureUnit) {
                    Text("Celsius (°C)").tag(TemperatureUnit.celsius)
                    Text("Fahrenheit (°F)").tag(TemperatureUnit.fahrenheit)
                }
                .onChange(of: settings.temperatureUnit) { _, _ in model.refreshDisplay() }
            }
            Section("Privacy") {
                Toggle(isOn: $settings.crashReports) {
                    Text("Send crash reports")
                    Text("Only the app version and the crash. No readings, names or files.")
                }
                .onChange(of: settings.crashReports) { _, _ in Telemetry.startIfEnabled() }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Safety

private struct SafetyTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: AppModel

    private var unit: TemperatureUnit { settings.temperatureUnit }
    private var snap: Snapshot { model.snapshot }
    private var signals: Signals? { model.decision?.signals }

    /// "custom" when the limits match no preset.
    private var presetBinding: Binding<String> {
        Binding(
            get: { SafetyPreset.matching(settings.config)?.rawValue ?? "custom" },
            set: { raw in
                guard let preset = SafetyPreset(rawValue: raw) else { return }
                settings.config = preset.apply(to: settings.config)
            })
    }

    var body: some View {
        Form {
            Section {
                Picker("Limits", selection: presetBinding) {
                    ForEach(SafetyPreset.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                    Text("Custom").tag("custom")
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Safety limits")
            } footer: {
                Text(SafetyPreset.matching(settings.config)?.summary
                     ?? "You changed the limits below. Pick a preset to go back to its values.")
                    .note()
            }

            Section {
                temperatureRule(title: "Stop when the CPU gets too hot", reading: Readout.cpuValue(snap, signals), averaged: true,
                                enabled: $settings.config.cpuEnabled, limit: $settings.config.cpuLimit, range: ConfigRange.cpuLimit,
                                wait: $settings.config.cpuSustainSeconds, explainWait: true)
            } header: {
                Text("Heat")
            }
            Section {
                temperatureRule(title: "Stop when the graphics chip gets too hot", reading: Readout.gpuValue(snap, signals), averaged: true,
                                enabled: $settings.config.gpuEnabled, limit: $settings.config.gpuLimit, range: ConfigRange.gpuLimit,
                                wait: $settings.config.gpuSustainSeconds)
            }
            Section {
                temperatureRule(title: "Stop when the battery gets too hot", reading: Readout.batteryValue(snap, signals),
                                enabled: $settings.config.batteryTempEnabled, limit: $settings.config.batteryTempLimit,
                                range: ConfigRange.batteryTempLimit, wait: $settings.config.batteryTempSustainSeconds)
            }
            Section {
                RuleToggle(title: "Stop when the battery heats up fast", detail: heatingNow,
                           isOn: $settings.config.batteryHeatingEnabled)
                if settings.config.batteryHeatingEnabled {
                    NumberRow(label: "Stop if it rises more than",
                              help: "Within 5 minutes, only with the lid closed on battery. Catches a Mac warming up in a bag.",
                              value: $settings.config.batteryHeatingRise, range: ConfigRange.batteryHeatingRise, step: 0.5) {
                        unit == .celsius ? String(format: "%.1f °C", $0) : String(format: "%.1f °F", $0 * 9 / 5)
                    }
                }
            }
            Section {
                RuleToggle(title: "Stop when macOS says the Mac is too hot", detail: "Now: \(Fmt.heat(snap.thermal))",
                           isOn: $settings.config.thermalEnabled,
                           detailColor: snap.thermal >= settings.config.thermalLimit && settings.config.thermalEnabled ? .orange : .secondary)
                if settings.config.thermalEnabled {
                    Picker(selection: $settings.config.thermalLimit) {
                        Text(Fmt.heat(.fair)).tag(ThermalLevel.fair)
                        Text(Fmt.heat(.serious)).tag(ThermalLevel.serious)
                        Text(Fmt.heat(.critical)).tag(ThermalLevel.critical)
                    } label: {
                        Text("Stop at")
                        Text("The heat level macOS reports itself. Works even when the sensors can't be read.")
                    }
                    if settings.config.thermalLimit < .critical {
                        NumberRow(label: "Only after it stays there for",
                                  help: "\(Fmt.heat(.critical)) always stops at once.",
                                  value: $settings.config.thermalSustainSeconds, range: ConfigRange.thermalSustainSeconds,
                                  step: 30) { $0 == 0 ? "No wait" : Fmt.seconds($0) }
                    }
                }
            }

            Section {
                RuleToggle(title: "Stop when the battery runs low", detail: batteryNow, isOn: $settings.config.floorEnabled)
                if settings.config.floorEnabled {
                    NumberRow(label: "Stop below",
                              help: "Starts again once you plug in, or when the battery is back at \(settings.config.floorPercent + 10) %.",
                              value: $settings.config.floorPercent, range: 5...60) { "\($0) %" }
                }
            } header: {
                Text("Battery")
            }

            Section {
                RuleToggle(title: "Stop after a maximum time", detail: "Ends even when everything else is fine.",
                           isOn: $settings.config.capEnabled)
                if settings.config.capEnabled {
                    NumberRow(label: "Maximum", value: $settings.config.capHours, range: 1...24) { Fmt.hours($0) }
                }
            } header: {
                Text("Time")
            }

            Section {
                LabeledContent {
                    Text("Stops after \(Fmt.seconds(settings.config.sensorFailureSeconds))")
                } label: {
                    Text("If the temperature can't be read")
                    Text("Always on. Unknown heat counts as too hot. Change the wait under Advanced.")
                }
            } footer: {
                Text("When a limit is reached, StayAwake stops and your Mac sleeps as usual again.").note()
            }
        }
        .formStyle(.grouped)
    }

    private var heatingNow: String {
        guard snap.lidClosed, snap.powerSource == .battery else { return "Runs with the lid closed on battery" }
        guard let rise = signals?.batteryRise else { return "Lid closed on battery" }
        let r = unit == .celsius ? max(0, rise) : max(0, rise) * 9 / 5
        return String(format: "Now up %.1f %@ in 5 min", r, unit.symbol)
    }

    private var batteryNow: String {
        guard let p = snap.batteryPercent else { return "No battery reading" }
        if snap.isCharging { return "Now \(p) %, charging" }
        return snap.powerSource == .ac ? "Now \(p) %, on power" : "Now \(p) %, on battery"
    }

    @ViewBuilder
    private func temperatureRule(title: String, reading: Double?, averaged: Bool = false, enabled: Binding<Bool>,
                                 limit: Binding<Double>, range: ClosedRange<Double>, wait: Binding<Int>,
                                 explainWait: Bool = false) -> some View {
        RuleToggle(title: title, detail: tempNow(reading, limit: limit.wrappedValue, averaged: averaged), isOn: enabled,
                   detailColor: tempColor(reading, limit: limit.wrappedValue, on: enabled.wrappedValue))
        if enabled.wrappedValue {
            NumberRow(label: "Stop above", value: limit, range: range) { Fmt.temp($0, unit) }
            NumberRow(label: "Only after it stays there for",
                      help: explainWait ? "The limit applies to the average of the last minute. The wait comes on top, so a short spike doesn't stop your work." : nil,
                      value: wait, range: ConfigRange.sustainSeconds, step: 10) { $0 == 0 ? "No wait" : Fmt.seconds($0) }
        }
    }

    private func tempNow(_ reading: Double?, limit: Double, averaged: Bool) -> String {
        guard let reading else { return "No reading right now" }
        let now = averaged ? "Last minute \(Fmt.temp(reading, unit))" : "Now \(Fmt.temp(reading, unit))"
        let gap = limit - reading
        if gap <= 0 { return "\(now), above the limit" }
        return "\(now), \(Fmt.tempDelta(gap, unit)) below the limit"
    }

    private func tempColor(_ reading: Double?, limit: Double, on: Bool) -> Color {
        guard on, let reading else { return .secondary }
        if reading >= limit { return .red }
        return limit - reading <= 5 ? .orange : .secondary
    }
}

// MARK: - When idle

private struct IdleTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: AppModel

    private var snap: Snapshot { model.snapshot }

    var body: some View {
        Form {
            Section {
                RuleToggle(title: "Stop when the Mac has nothing to do", detail: loadNow, isOn: $settings.config.idleEnabled)
                if settings.config.idleEnabled {
                    NumberRow(label: "Counts as idle below",
                              help: "How busy the processor is, on average over all cores.",
                              value: $settings.config.idleCpuPercent, range: 2...50) { "\($0) % busy" }
                    NumberRow(label: "For", value: $settings.config.idleMinutes, range: 5...120, step: 5) { Fmt.minutes($0) }
                }
            } header: {
                Text("Stop when nothing is happening")
            } footer: {
                Text("Only counts while the lid is closed, so reading or typing never looks idle.").note()
            }

            Section {
                RuleToggle(title: "Stop when there is no internet", detail: snap.networkUsable ? "Online now" : "Offline now",
                           isOn: $settings.config.networkEnabled,
                           detailColor: snap.networkUsable ? .secondary : .orange)
                if settings.config.networkEnabled {
                    NumberRow(label: "Offline for", value: $settings.config.networkMinutes, range: 2...120) { Fmt.minutes($0) }
                }
            } footer: {
                Text("Agents that work online can't do much without a connection.").note()
            }

            Section {
                RuleToggle(title: "Stop when the lid stays closed on battery", detail: lidNow, isOn: $settings.config.lidEnabled)
                if settings.config.lidEnabled {
                    NumberRow(label: "Closed for", value: $settings.config.lidMinutes, range: 10...480, step: 10) { Fmt.minutes($0) }
                }
            } footer: {
                Text("A closed Mac in a bag warms up and drains. Plugged in, this limit does not count.").note()
            }

            Section {
                RuleToggle(title: "Stop when certain apps are not running", detail: "Coming in a later release",
                           isOn: $settings.config.watchedEnabled)
                if settings.config.watchedEnabled {
                    WatchedNamesField(settings: settings)
                    NumberRow(label: "None running for", value: $settings.config.watchedMinutes, range: 5...240, step: 5) { Fmt.minutes($0) }
                }
            } footer: {
                if settings.config.watchedEnabled {
                    Text("The app check is not built yet. Until then, switching this on stops StayAwake after the time above.").note()
                }
            }
        }
        .formStyle(.grouped)
    }

    private var loadNow: String {
        guard let load = snap.cpuLoadPercent else { return "No reading right now" }
        return "Now \(Int(load.rounded())) % busy" + (snap.lidClosed ? "" : ", lid open")
    }

    private var lidNow: String {
        guard snap.lidClosed else { return "Lid open now" }
        return snap.powerSource == .battery ? "Closed now, on battery" : "Closed now, plugged in"
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
        TextField(text: $text, prompt: Text("claude, codex")) {
            Text("Apps to watch")
            Text("Process names, separated by commas.")
        }
        .onChange(of: text) { _, new in settings.config.watchedNames = new.split(separator: ",").map { String($0) } }
    }
}

// MARK: - Schedule

private let weekdayOrder = [1, 2, 3, 4, 5, 6, 0]
private let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
private let weekdayShort = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

private struct ScheduleTab: View {
    @ObservedObject var settings: AppSettings
    @State private var draft: Schedule
    @State private var problem: String?
    @State private var selected = 1

    init(settings: AppSettings) {
        self.settings = settings
        _draft = State(initialValue: settings.config.schedule.normalized())
    }

    var body: some View {
        Form {
            Section {
                Picker("StayAwake may keep the Mac awake", selection: Binding(get: { draft.enabled }, set: { draft.enabled = $0; commit() })) {
                    Text("Any time").tag(false)
                    Text("Only during the hours below").tag(true)
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("When to stay awake")
            } footer: {
                Text(draft.enabled
                     ? "Outside these hours StayAwake waits, and the Mac sleeps as usual. Click a day to change it."
                     : "StayAwake keeps the Mac awake whenever you turn it on.")
                    .note()
            }

            if draft.enabled {
                Section {
                    WeekOverview(schedule: draft, selected: $selected)
                }
                Section {
                    dayEditor(selected)
                } header: {
                    Text(weekdayNames[selected])
                } footer: {
                    if let problem {
                        Text(problem).font(.caption).foregroundStyle(.red).padding(.horizontal, 10).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("Times use this Mac's time zone. An end time of 00:00 means midnight. To run overnight, end one day at 00:00 and start the next day at 00:00.")
                            .note()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func commit() {
        for (i, windows) in draft.days.enumerated() {
            for w in windows where w.end <= w.start {
                problem = "\(weekdayNames[i]): the end time must be after the start time. Not saved yet."
                return
            }
        }
        problem = nil
        settings.config.schedule = draft
        draft = settings.config.schedule
    }

    @ViewBuilder
    private func dayEditor(_ day: Int) -> some View {
        if draft.days[day].isEmpty {
            Text("Not allowed on \(weekdayNames[day]). Add hours to allow it.").foregroundStyle(.secondary)
        }
        ForEach(draft.days[day].indices, id: \.self) { i in
            HStack(spacing: 8) {
                Text("From")
                ClockPicker(label: "Start time", minutes: windowBinding(day, i, \.start), isEnd: false)
                Text("to")
                ClockPicker(label: "End time", minutes: windowBinding(day, i, \.end), isEnd: true)
                Spacer()
                Button { draft.days[day].remove(at: i); commit() } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove these hours")
            }
        }
        HStack {
            Button("Add Hours") { addWindow(day) }
                .disabled(draft.days[day].count >= Schedule.maxWindowsPerDay || nextFreeStart(day) == nil)
            Spacer()
            Menu("Copy \(weekdayNames[day]) to") {
                Button("All weekdays") { copy(day, to: [1, 2, 3, 4, 5]) }
                Button("Every day") { copy(day, to: Array(0..<7)) }
                Divider()
                ForEach(weekdayOrder.filter { $0 != day }, id: \.self) { other in
                    Button(weekdayNames[other]) { copy(day, to: [other]) }
                }
            }
            .fixedSize()
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

/// The native macOS time field, bound to minutes since midnight and rounded
/// to 5 minutes. For an end time, 00:00 means midnight at the end of the day.
private struct ClockPicker: View {
    let label: String
    @Binding var minutes: Int
    let isEnd: Bool

    private static var calendar: Calendar { Calendar.current }

    private static func date(_ minutes: Int) -> Date {
        let m = minutes % 1440
        return calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: m / 60, minute: m % 60)) ?? Date()
    }

    private var binding: Binding<Date> {
        Binding(
            get: { Self.date(minutes) },
            set: { newDate in
                let parts = Self.calendar.dateComponents([.hour, .minute], from: newDate)
                let raw = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                let old = minutes % 1440
                let step = Schedule.stepMinutes
                var snapped = Int((Double(raw) / Double(step)).rounded()) * step
                // A one-minute arrow click would round back to the old value; move a whole step instead.
                if snapped == old && raw != old { snapped = old + (raw > old ? step : -step) }
                snapped = (snapped + 1440) % 1440
                minutes = isEnd && snapped == 0 ? 1440 : snapped
            })
    }

    var body: some View {
        DatePicker(label, selection: binding, displayedComponents: .hourAndMinute)
            .datePickerStyle(.stepperField)
            .labelsHidden()
    }
}

/// Seven bars on a 24 hour scale, one per day. Click a day to edit it.
private struct WeekOverview: View {
    let schedule: Schedule
    @Binding var selected: Int

    private let labelWidth: CGFloat = 40
    private let totalWidth: CGFloat = 56

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                Color.clear.frame(width: labelWidth, height: 1)
                GeometryReader { g in
                    ForEach([6, 12, 18], id: \.self) { h in
                        Text(String(format: "%02d:00", h))
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            .fixedSize()
                            .position(x: g.size.width * CGFloat(h) / 24, y: 6)
                    }
                }
                .frame(height: 12)
                Color.clear.frame(width: totalWidth, height: 1)
            }
            .padding(.horizontal, 6)
            ForEach(weekdayOrder, id: \.self) { day in
                Button { selected = day } label: { row(day) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(weekdayNames[day]), \(summary(day))")
            }
        }
        .padding(.vertical, 2)
    }

    private func row(_ day: Int) -> some View {
        let windows = schedule.days[day]
        let isSelected = selected == day
        return HStack(spacing: 8) {
            Text(weekdayShort[day])
                .fontWeight(isSelected ? .semibold : .regular)
                .frame(width: labelWidth, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                    ForEach([6, 12, 18], id: \.self) { h in
                        Rectangle().fill(Color.secondary.opacity(0.25))
                            .frame(width: 1)
                            .offset(x: g.size.width * CGFloat(h) / 24)
                    }
                    ForEach(windows.indices, id: \.self) { i in
                        let w = windows[i]
                        RoundedRectangle(cornerRadius: 3).fill(Color.accentColor)
                            .frame(width: max(2, g.size.width * CGFloat(w.end - w.start) / 1440))
                            .offset(x: g.size.width * CGFloat(w.start) / 1440)
                    }
                }
            }
            .frame(height: 14)
            Text(summary(day))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: totalWidth, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear))
        .contentShape(Rectangle())
    }

    private func summary(_ day: Int) -> String {
        let total = schedule.days[day].reduce(0) { $0 + $1.end - $1.start }
        guard total > 0 else { return "Off" }
        let h = total / 60, m = total % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) m"
    }
}

// MARK: - Notifications

private struct NotificationsTab: View {
    @ObservedObject var settings: AppSettings
    private let sounds = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]

    var body: some View {
        Form {
            Section("Tell me") {
                Toggle(isOn: $settings.config.notifyOnTrip) {
                    Text("When StayAwake stops")
                    Text("Says which limit was reached.")
                }
                Toggle(isOn: Binding(get: { settings.config.headsUpMinutes > 0 },
                                     set: { settings.config.headsUpMinutes = $0 ? 5 : 0 })) {
                    Text("Shortly before it stops")
                    Text("Time to plug in or let the Mac cool down.")
                }
                if settings.config.headsUpMinutes > 0 {
                    NumberRow(label: "Warn me", value: $settings.config.headsUpMinutes, range: 1...30) { "\($0) min before" }
                }
                Toggle(isOn: $settings.config.alertOnUnplug) {
                    Text("When the charger is unplugged")
                    Text("Only while StayAwake is on.")
                }
                Toggle("When I turn StayAwake on or off myself", isOn: $settings.config.notifyOnManualArm)
            }
            Section("Sound") {
                Picker("Sound when StayAwake stops", selection: $settings.tripSound) {
                    Text("None").tag("")
                    Divider()
                    ForEach(sounds, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: settings.tripSound) { _, name in if !name.isEmpty { NSSound(named: NSSound.Name(name))?.play() } }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Advanced

private struct AdvancedTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: AppModel

    private var unit: TemperatureUnit { settings.temperatureUnit }

    var body: some View {
        Form {
            Section {
                Label {
                    Text("The defaults work well for almost everyone. Only change these if you know why.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }

            Section {
                NumberRow(label: "CPU", value: $settings.config.cpuClearMargin, range: ConfigRange.clearMargin) { "\(Fmt.tempDelta($0, unit)) cooler" }
                NumberRow(label: "Graphics chip", value: $settings.config.gpuClearMargin, range: ConfigRange.clearMargin) { "\(Fmt.tempDelta($0, unit)) cooler" }
                NumberRow(label: "Battery", value: $settings.config.batteryTempClearMargin, range: ConfigRange.batteryClearMargin) { "\(Fmt.tempDelta($0, unit)) cooler" }
            } header: {
                Text("Cooling down after a heat stop")
            } footer: {
                Text("A part only counts as cool again once it drops this far below its limit. This stops StayAwake from flipping on and off right at the limit.").note()
            }

            Section("Temperature sensors") {
                NumberRow(label: "Stop if the temperature can't be read for",
                          value: $settings.config.sensorFailureSeconds, range: 30...300, step: 10) { Fmt.seconds($0) }
                Picker(selection: $settings.config.sensorPreference) {
                    Text("Automatic").tag(SensorPreference.automatic)
                    Text("Thermal sensors (HID)").tag(SensorPreference.hid)
                    Text("System controller (SMC)").tag(SensorPreference.smc)
                    Text("macOS heat level only").tag(SensorPreference.thermalStateOnly)
                } label: {
                    Text("Read temperatures from")
                    Text("Automatic picks the best source on this Mac.")
                }
            }

            Section {
                NumberRow(label: "While keeping the Mac awake", value: $settings.config.holdingIntervalSeconds,
                          range: 5...60, step: 5) { "every \(Fmt.seconds($0))" }
                NumberRow(label: "While off or waiting", value: $settings.config.offIntervalSeconds,
                          range: 30...300, step: 30) { "every \(Fmt.seconds($0))" }
                NumberRow(label: "Fallback if StayAwake stops responding",
                          help: "The helper turns normal sleep back on by itself after this time. StayAwake checks in every 10 s.",
                          value: $settings.config.leaseSeconds, range: 30...120, step: 10) { Fmt.seconds($0) }
            } header: {
                Text("How often StayAwake checks")
            }

            Section("Activity log") {
                Toggle("Keep a log of what StayAwake did", isOn: Binding(get: { settings.config.logRetentionDays > 0 },
                                                                        set: { settings.config.logRetentionDays = $0 ? 30 : 0 }))
                if settings.config.logRetentionDays > 0 {
                    NumberRow(label: "Keep entries for", value: $settings.config.logRetentionDays, range: 7...365) { "\($0) days" }
                }
                Toggle("Add readings to the log", isOn: Binding(get: { settings.config.sampleMinutes > 0 },
                                                                set: { settings.config.sampleMinutes = $0 ? 5 : 0 }))
                if settings.config.sampleMinutes > 0 {
                    NumberRow(label: "While awake, every", value: $settings.config.sampleMinutes, range: 1...60) { Fmt.minutes($0) }
                }
            }

            Section("Sleep control") {
                LabeledContent("Method", value: model.backend.name)
                LabeledContent("Status", value: model.setupMessage ?? "Ready")
                HStack {
                    Button("Allow Sleep Now") { model.restoreSleepNow() }
                        .help("Turn normal Mac sleep back on right away")
                    Spacer()
                    Button("Export Log…", action: exportLog)
                    Button("Copy Diagnostics", action: copyDiagnostics)
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
        let sig = model.decision?.signals
        let lines = [
            "StayAwake \(Telemetry.appVersion)",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "backend: \(model.backend.name), \(model.setupMessage ?? "ready")",
            "phase: \(model.engine.phase.rawValue), SleepDisabled: \(model.sleepDisabled.map { $0 ? "1" : "0" } ?? "unknown")",
            "CPU \(s.cpuTemperature.map { String(format: "%.1f", $0) } ?? "n/a"), GPU \(s.gpuTemperature.map { String(format: "%.1f", $0) } ?? "n/a"), battery temp \(s.batteryTemperature.map { String(format: "%.1f", $0) } ?? "n/a")",
            "60 s average: CPU \(sig?.cpu.smoothed.map { String(format: "%.1f", $0) } ?? "n/a") (\(sig?.cpu.source.rawValue ?? "none")), GPU \(sig?.gpu.smoothed.map { String(format: "%.1f", $0) } ?? "n/a") (\(sig?.gpu.source.rawValue ?? "none"))",
            "battery \(s.batteryPercent.map(String.init) ?? "n/a")%, \(s.powerSource.rawValue), lid \(s.lidClosed ? "closed" : "open"), thermal \(s.thermal.rawValue)",
            "limits: CPU \(c.cpuLimit), GPU \(c.gpuLimit), battery \(c.batteryTempLimit), floor \(c.floorPercent)%, sensor \(c.sensorPreference.rawValue)",
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
