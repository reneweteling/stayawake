import SwiftUI
import AppKit

/// Settings, About: the app icon, version and updates, then a "Built by"
/// card with René's logo. Same structure as TidyDrive's About.
struct AboutView: View {
    /// StayAwake's amber, the same as the site and the menu bar warning.
    static let accent = Color(red: 1.0, green: 0.71, blue: 0.28)

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                updatesRow
                HStack(spacing: 16) {
                    Link("Website", destination: URL(string: "https://reneweteling.github.io/stayawake/")!)
                    Link("Source", destination: URL(string: "https://github.com/reneweteling/stayawake")!)
                    Link("Report a bug", destination: URL(string: "https://github.com/reneweteling/stayawake/issues/new?version=\(Telemetry.appVersion)")!)
                }
                .font(.caption)
                builtByCard
                recovery
                Text("© \(Self.year) Felobo B.V. · PolyForm Noncommercial 1.0.0")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 22)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 88, height: 88)
            VStack(spacing: 2) {
                Text("StayAwake").font(.title2.weight(.semibold))
                Text("Version \(Telemetry.appVersion)").font(.caption).foregroundStyle(.secondary)
            }
            Text("Awake in the bag. Asleep when it matters.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// StayAwake has no update checker yet. Same layout as TidyDrive, the
    /// button opens the releases page instead of checking in the app.
    private var updatesRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
            Text("New versions are on the releases page").font(.caption).foregroundStyle(.secondary)
            Button {
                NSWorkspace.shared.open(URL(string: "https://github.com/reneweteling/stayawake/releases")!)
            } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Check for updates on GitHub")
        }
    }

    private var builtByCard: some View {
        VStack(spacing: 14) {
            Text("BUILT BY")
                .font(.caption2.weight(.semibold))
                .tracking(2)
                .foregroundStyle(.secondary)

            if let logo = Self.wetelingLogo {
                Image(nsImage: logo)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(height: 64)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .accessibilityLabel("Weteling logo")
            }

            VStack(spacing: 3) {
                Text("René Weteling").font(.title3.weight(.semibold))
                Text("Agentic Developer · Felobo B.V.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("One developer. A fleet of agents.")
                    .font(.caption)
                    .foregroundStyle(Self.accent)
            }

            HStack(spacing: 8) {
                PillLink(systemImage: "sparkles", label: "Start a project",
                         url: URL(string: "https://www.weteling.com/#contact")!, prominent: true)
                PillLink(systemImage: "globe", label: "weteling.com", url: URL(string: "https://www.weteling.com")!)
                PillLink(systemImage: "chevron.left.forwardslash.chevron.right", label: "reneweteling",
                         url: URL(string: "https://github.com/reneweteling")!)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5))
        .padding(.horizontal, 12)
    }

    /// The manual way back to normal sleep, for when the app itself can't.
    private var recovery: some View {
        VStack(spacing: 4) {
            Text("If your Mac ever stops sleeping, run this in Terminal:")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(BackendFactory.manualRestoreCommand)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(BackendFactory.manualRestoreCommand, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy the command")
            }
        }
    }

    static var year: String { String(Calendar.current.component(.year, from: Date())) }

    /// The SVG is rasterised once. Handing an SVG-backed NSImage straight to
    /// SwiftUI makes CoreSVG decode on every draw, which can crash now and
    /// then. build.sh puts the file in Contents/Resources.
    static let wetelingLogo: NSImage? = {
        guard let url = Bundle.main.url(forResource: "weteling-logo", withExtension: "svg"),
              let svg = NSImage(contentsOf: url) else { return nil }
        let height: CGFloat = 128
        let scale = svg.size.height > 0 ? height / svg.size.height : 1
        let size = NSSize(width: max(svg.size.width * scale, 1), height: height)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        svg.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }()
}

private struct PillLink: View {
    let systemImage: String
    let label: String
    let url: URL
    var prominent = false
    @State private var hover = false

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.caption2)
                Text(label).font(.caption.weight(prominent ? .semibold : .regular))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(prominent || hover ? Color.black : .primary)
            .background(Capsule().fill(prominent || hover ? AboutView.accent : Color.secondary.opacity(0.14)))
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(prominent || hover ? 0 : 0.22), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}
