import SwiftUI
import StayAwakeCore

/// Section 3 of the spec: the switch, the readouts with their limits, what
/// trips next, the last event and the footer.
struct PopoverView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    let openSettings: () -> Void
    let quit: () -> Void

    private var cfg: Config { settings.config.clamped() }
    private var unit: TemperatureUnit { settings.temperatureUnit }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.unplugBanner { banner("Unplugged. StayAwake keeps this Mac awake on battery.", color: .orange) }
            if let text = model.message { banner(text, color: .red, dismiss: model.dismissMessage) }
            if model.engine.phase == .tripped { trippedBlock }
            Divider()
            readouts
            if model.isArmed { Divider(); nextToTrip }
            Divider()
            armFor
            Text(model.lastEvent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: Header

    private var armedBinding: Binding<Bool> {
        Binding(get: { model.isArmed }, set: { on in if on { model.arm() } else { model.disarm() } })
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: model.status.symbol)
                Text("Stay awake").font(.headline)
                Spacer()
                Toggle("Stay awake", isOn: armedBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(model.setupMessage != nil && !model.isArmed)
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var subtitle: String {
        switch model.engine.phase {
        case .off:
            return model.setupMessage ?? "Off. This Mac sleeps as usual."
        case .waiting:
            return model.status.tooltip
        case .holding:
            var parts: [String] = []
            if let held = model.heldFor { parts.append("Holding for \(Readout.duration(held))") } else { parts.append("Holding") }
            if let d = model.decision, let limit = Readout.limitingTime(d.margins, timerLeft: model.timerLeft) {
                parts.append("\(Readout.duration(limit.seconds)) left (\(limit.label))")
            }
            return parts.joined(separator: " · ")
        case .tripped:
            return "Stopped by a rule."
        }
    }

    private func banner(_ text: String, color: Color, dismiss: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }

    private var trippedBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sleep restored").font(.headline)
            if let trip = model.engine.lastTrip {
                let at = model.trippedAt.map { Readout.clock($0, in: .current) } ?? ""
                Text("\(at) · \(trip.message)").font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Button("Re-arm") { model.arm() }
        }
    }

    // MARK: Readouts

    private func tone(_ rule: RuleID) -> Color {
        guard let m = model.decision?.margins.first(where: { $0.rule == rule }) else { return .primary }
        if model.decision?.failing.contains(where: { $0.rule == rule }) == true || m.fraction <= 0 { return .red }
        if m.fraction <= Forecast.warningFraction { return .orange }
        return .primary
    }

    private func row(_ label: String, _ value: String, color: Color = .primary) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(color).monospacedDigit()
        }
        .font(.callout)
    }

    private var readouts: some View {
        let s = model.snapshot
        return VStack(alignment: .leading, spacing: 5) {
            row("CPU", Readout.value(Readout.cpu(s, cfg, unit: unit), label: "CPU"), color: tone(.cpuTemperature))
            row("GPU", Readout.value(Readout.gpu(s, cfg, unit: unit), label: "GPU"), color: tone(.gpuTemperature))
            row("Battery", Readout.value(Readout.batteryTemperature(s, cfg, unit: unit), label: "Battery"), color: tone(.batteryTemperature))
            row("Battery", Readout.value(Readout.batteryLevel(s, cfg), label: "Battery"), color: tone(.batteryFloor))
            ProgressView(value: Double(s.batteryPercent ?? 0), total: 100)
                .tint(tone(.batteryFloor) == .primary ? .accentColor : tone(.batteryFloor))
            Text(batteryState).font(.caption).foregroundStyle(.secondary)
            row("Lid", lidText)
            row("Network", s.networkUsable ? "Online" : "Offline", color: s.networkUsable ? .primary : .orange)
            row("System sleep", systemSleepText, color: systemSleepColor)
        }
    }

    private var batteryState: String {
        let s = model.snapshot
        let source = s.powerSource == .ac ? "On power" : "On battery"
        return s.isCharging ? "\(source), charging" : (s.powerSource == .ac ? source : "\(source), discharging")
    }

    private var lidText: String {
        let s = model.snapshot
        guard s.lidClosed else { return "Open" }
        let onBattery = s.powerSource == .battery
        if onBattery, let m = model.decision?.margins.first(where: { $0.rule == .lidOnBattery }), model.engine.lidSince != nil {
            let total = Double(cfg.lidMinutes) * 60
            return "Closed · on battery \(Readout.duration(max(0, total - (m.seconds ?? total))))"
        }
        return onBattery ? "Closed · on battery" : "Closed"
    }

    private var systemSleepText: String {
        switch model.sleepDisabled {
        case true: return "Disabled"
        case false: return "Allowed"
        default: return "Unknown"
        }
    }

    private var systemSleepColor: Color {
        // Disabled while we do not hold means someone set it by hand.
        model.sleepDisabled == true && model.engine.phase != .holding ? .orange : .primary
    }

    // MARK: Next to trip

    private var nextToTrip: some View {
        let list = (model.decision?.nextToTrip ?? []).filter(Readout.isMeaningful)
        return VStack(alignment: .leading, spacing: 4) {
            if let first = list.first {
                row("Next to trip", Readout.marginLine(first), color: first.fraction <= Forecast.warningFraction ? .orange : .primary)
                if list.count > 1 {
                    row("Then", list.dropFirst().map { Readout.marginLine($0) }.joined(separator: " · "))
                }
            } else {
                row("Next to trip", "Nothing close")
            }
        }
    }

    // MARK: Arm for and footer

    private var armFor: some View {
        HStack {
            Text("Arm for").font(.callout)
            Spacer()
            Picker("Arm for", selection: $model.armDuration) {
                ForEach(ArmDuration.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 170)
            .disabled(model.isArmed)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Settings…", action: openSettings)
            Button("Open log") { EventLog.open() }
            Button("Restore sleep now") { model.restoreSleepNow() }
            Spacer()
            Button("Quit", action: quit).keyboardShortcut("q")
        }
        .buttonStyle(.link)
        .font(.callout)
    }
}

extension ArmDuration {
    var title: String {
        switch self {
        case .untilTrip: return "Until a rule trips"
        case .oneHour: return "1 hour"
        case .twoHours: return "2 hours"
        case .fourHours: return "4 hours"
        case .untilScheduleEnd: return "Until schedule end"
        }
    }
}
