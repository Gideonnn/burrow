import BurrowKit
import SwiftUI

// The sidebar pieces every Burrow app shares, styled like Mail's.

/// Mail's sidebar counts are semibold, which SwiftUI's `.badge` cannot be, so
/// every count in the sidebar is this text instead.
public struct SidebarCount: View {
    let count: Int

    public init(count: Int) { self.count = count }

    public var body: some View {
        Text(count > 0 ? count.formatted() : "")
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .accessibilityHidden(count == 0)
    }
}

/// SwiftUI draws sidebar section headers in tertiary grey; Mail's are secondary.
public struct SidebarSectionHeader: View {
    let title: String

    public init(_ title: String) { self.title = title }

    public var body: some View {
        Text(title).foregroundStyle(.secondary)
    }
}

public struct CountedLabel: View {
    let title: String
    let icon: String
    let count: Int

    public init(title: String, icon: String, count: Int) {
        self.title = title
        self.icon = icon
        self.count = count
    }

    public var body: some View {
        HStack(spacing: 6) {
            Label(title, systemImage: icon)
            Spacer(minLength: 0)
            SidebarCount(count: count)
        }
    }
}

/// At the bottom of the sidebar: a new build is ready, restart to use it.
public struct UpdateBanner: View {
    @Environment(Updater.self) private var updater
    let appName: String
    let restart: () -> Void

    public init(appName: String, restart: @escaping () -> Void) {
        self.appName = appName
        self.restart = restart
    }

    public var body: some View {
        if let version = updater.ready {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
                Text("Update klaar").font(.caption.weight(.semibold))
                Spacer()
                Button("Herstart", action: restart)
                    .controlSize(.small)
            }
            .help("Build \(version) staat klaar; \(appName) start opnieuw op met de nieuwe versie.")
            .padding(10)
            .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 8)
        }
    }
}

/// The server card under the sidebar: the host, and who is logged in or that
/// the server is away for a moment.
public struct ConnectionBadge: View {
    let host: String
    let detail: String
    let reachable: Bool
    let busy: Bool
    let appName: String

    public init(host: String, detail: String, reachable: Bool, busy: Bool = false, appName: String) {
        self.host = host
        self.detail = detail
        self.reachable = reachable
        self.busy = busy
        self.appName = appName
    }

    public var body: some View {
        HStack(spacing: 8) {
            Circle().fill(reachable ? BurrowColor.success : BurrowColor.warning).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(host).font(.caption.weight(.semibold))
                Text(reachable ? detail : "Server even niet bereikbaar")
                    .font(.caption2)
                    .foregroundStyle(reachable ? AnyShapeStyle(.secondary) : AnyShapeStyle(BurrowColor.warning))
                    .lineLimit(1)
            }
            Spacer()
            if busy { ProgressView().controlSize(.mini) }
        }
        .padding(10)
        .help(reachable ? "Verbonden" : "\(appName) probeert het vanzelf opnieuw.")
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
        .padding(8)
    }
}
