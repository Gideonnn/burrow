import BurrowUI
import AppKit
import HedwigCore
import SwiftUI

// The line-up of a festival or concert, read by the server from the
// organiser's website: per day, the big names large like on a poster.

struct OutingLineupCard: View {
    @Environment(AppModel.self) private var model
    let outing: Outing
    let lineup: OutingLineup
    @State private var asking = false

    private var working: Bool { lineup.status == .working || asking }
    private var canOrganize: Bool { model.me?.can(.organize) == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if lineup.status == .failed {
                failure
            }
            if lineup.artists.isEmpty {
                if lineup.status == .working {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Hedwig leest de website van \(lineup.sourceHost ?? "het festival")…").foregroundStyle(.secondary)
                    }
                } else if lineup.status == .ready {
                    Text("Nog geen namen bekend.").foregroundStyle(.secondary)
                }
            } else {
                ForEach(lineup.days()) { day in
                    LineupDayView(day: day)
                }
            }
            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: lineup.status) { asking = false }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Line-up", systemImage: "music.mic").font(.headline)
            Spacer()
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(working ? 360 : 0))
                    .animation(working ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: working)
            }
            .buttonStyle(.borderless)
            .disabled(working || !canOrganize)
            .help(working ? "Hedwig leest de website" : "Lees de line-up opnieuw")
            .accessibilityLabel("Vernieuw de line-up")
            Button {
                Task { await model.removeLineup(outing.id) }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .disabled(!canOrganize)
            .help("Haal de line-up weg; je kunt hem later opnieuw zoeken")
            .accessibilityLabel("Haal de line-up weg")
        }
        .foregroundStyle(.secondary)
    }

    private var failure: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(lineup.error ?? "De line-up kon niet worden gelezen.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Probeer opnieuw", action: refresh).controlSize(.small).disabled(working || !canOrganize)
        }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let note = lineup.note, !note.isEmpty {
                Text(note).italic().foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Text(lineup.updatedText())
                if let host = lineup.sourceHost, let url = lineup.sourceURL {
                    Text("·")
                    Button("Bron: \(host)") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.link)
                        .help(url.absoluteString)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
    }

    private func refresh() {
        asking = true
        Task {
            await model.refreshLineup(outing.id)
            if model.outings.first(where: { $0.id == outing.id })?.lineup?.status != .working { asking = false }
        }
    }
}

/// One day: its title small and spaced, the headliners large, the rest smaller.
private struct LineupDayView: View {
    let day: LineupDay

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(day.title.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(day.day == nil ? Color.secondary : Color.pink)
            if !day.headliners.isEmpty {
                FlowLayout(spacing: 14) {
                    ForEach(day.headliners, id: \.self) { ArtistName(artist: $0, size: 26, weight: .heavy) }
                }
            }
            if !day.others.isEmpty {
                FlowLayout(spacing: 12) {
                    ForEach(day.others, id: \.self) { ArtistName(artist: $0, size: 16, weight: .semibold) }
                }
            }
        }
    }
}

private struct ArtistName: View {
    let artist: LineupArtist
    let size: CGFloat
    let weight: Font.Weight

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(artist.name)
                .font(.system(size: size, weight: weight))
                .lineLimit(1)
            if let detail = artist.detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .textSelection(.enabled)
    }
}

/// For a festival or concert without a line-up yet: one quiet button.
struct LineupSearchButton: View {
    @Environment(AppModel.self) private var model
    let outing: Outing
    @State private var asking = false

    var body: some View {
        HStack(spacing: 8) {
            button
            if !outing.hasWebsite {
                Text("Voeg eerst de website toe").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var button: some View {
        Button {
            asking = true
            Task {
                await model.refreshLineup(outing.id)
                asking = false
            }
        } label: {
            HStack(spacing: 6) {
                if asking { ProgressView().controlSize(.mini) } else { Image(systemName: "music.mic") }
                Text("Line-up zoeken")
            }
        }
        .controlSize(.small)
        .disabled(!outing.hasWebsite || asking || model.me?.can(.organize) != true)
        .help(outing.hasWebsite ? "Hedwig leest de line-up van de website van het festival" : "Voeg eerst de website toe")
    }
}
