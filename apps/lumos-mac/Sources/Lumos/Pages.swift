import BurrowUI
import LumosCore
import LumosUI
import SwiftUI

/// What the scope passed, each with "Terugzetten". Not now is no dislike.
struct PassedPage: View {
    @Environment(LumosModel.self) private var model

    var body: some View {
        VerdictPage(
            title: "Overgeslagen",
            note: "Niet nu is geen afkeer, en ‘Al gezien’ verlaagt de smaak niet.",
            empty: "Niets overgeslagen. Gebruik N of de knop Niet nu.",
            action: "Terugzetten")
    }
}

/// "More like this" and "less like this" per title.
struct TastePage: View {
    var body: some View {
        VerdictPage(
            title: "Smaak",
            note: "Alles begint neutraal. Bijstellingen gelden alleen voor voorstellen, nooit voor zoeken.",
            empty: "Nog geen bijstellingen. Kies in de details Meer of Minder zoals dit.",
            action: "Verwijder")
    }
}

struct VerdictPage: View {
    @Environment(LumosModel.self) private var model
    let title: String
    let note: String
    let empty: String
    let action: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Text(note).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                if model.verdictItems.isEmpty {
                    EmptyRow(text: empty).padding(.horizontal, -24)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.verdictItems) { verdict in
                            HStack(spacing: 10) {
                                Artwork(title: verdict.title, style: .poster)
                                    .frame(width: 30, height: 45)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                                Button(verdict.title.title) { model.open(verdict.title.ref, focusInside: true) }
                                    .buttonStyle(.plain)
                                    .fontWeight(.semibold)
                                Text(label(verdict)).foregroundStyle(.secondary)
                                Spacer()
                                Text("door \(verdict.by.name)").foregroundStyle(.secondary)
                                Button(action) { Task { await model.restore(verdict) } }
                                    .controlSize(.small)
                            }
                            .font(.system(size: 12))
                            .padding(.vertical, 6)
                            Divider()
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private func label(_ verdict: Verdict) -> String {
        switch verdict.kind {
        case .seen: "Al gezien"
        case .notNow: verdict.reason ?? "Niet nu"
        case .moreLikeThis: "Meer zoals dit"
        case .lessLikeThis: "Minder zoals dit"
        }
    }
}

/// What Dobby is fetching and how far, and what it holds, with a delete for
/// what Radarr or Sonarr manages.
struct ManagePage: View {
    @Environment(LumosModel.self) private var model
    @State private var removing: ManageItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if model.status?.requests != true {
                    EmptyRow(text: "Beheren werkt alleen met Seerr gekoppeld.").padding(.horizontal, -24)
                } else if let answer = model.manageAnswer {
                    section("Bezig", note: "Aangevraagd, wacht op de release of wordt gedownload",
                            empty: "Er wordt niets aangevraagd of gedownload.", items: answer.busy, busy: true)
                    section("In Jellyfin", note: "\(answer.library.count) titels, nieuwste eerst",
                            empty: "Nog niets in Jellyfin.", items: answer.library, busy: false)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(24)
        }
        .confirmationDialog(
            removing.map { "\($0.title.title) van Dobby verwijderen?" } ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { item in
            Button("Verwijderen", role: .destructive) { Task { await model.removeFromLibrary(item) } }
            Button("Annuleren", role: .cancel) {}
        } message: { item in
            Text("\(item.title.mediaType == .movie ? "Radarr" : "Sonarr") wist de bestanden. Lijsten blijven staan; opnieuw Ja vraagt hem weer aan.")
        }
    }

    @ViewBuilder
    private func section(_ title: String, note: String, empty: String, items: [ManageItem], busy: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(note).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            if items.isEmpty {
                EmptyRow(text: empty).padding(.horizontal, -24)
            } else {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        row(item, busy: busy)
                        Divider()
                    }
                }
            }
        }
    }

    private func row(_ item: ManageItem, busy: Bool) -> some View {
        HStack(spacing: 10) {
            Artwork(title: item.title, style: .poster)
                .frame(width: 30, height: 45)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 2) {
                Button(item.title.title) { model.open(item.title.ref, focusInside: true) }
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                Text(line(item, busy: busy)).foregroundStyle(.secondary)
            }
            Spacer()
            if busy {
                progress(item)
            } else if model.canDelete {
                Button("Verwijderen", systemImage: "trash", role: .destructive) { removing = item }
                    .controlSize(.small)
                    .disabled(!item.removable)
                    .help(item.removable
                        ? "Wist de bestanden van Dobby"
                        : "\(item.title.mediaType == .movie ? "Radarr" : "Sonarr") beheert deze titel niet; hij is met de hand toegevoegd")
            }
        }
        .font(.system(size: 12))
        .padding(.vertical, 6)
    }

    private func line(_ item: ManageItem, busy: Bool) -> String {
        let kind = item.title.mediaType == .movie ? "Film" : "Serie"
        let year = item.title.year.map(String.init)
        let status = busy || item.title.availability == .partiallyAvailable ? item.title.availability.label : nil
        return [kind, year, status].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private func progress(_ item: ManageItem) -> some View {
        if let download = item.download {
            HStack(spacing: 8) {
                if let eta = Self.eta(download.eta) {
                    Text("klaar rond \(eta)").foregroundStyle(.secondary)
                }
                ProgressView(value: download.progress).frame(width: 140)
                Text("\(Int((download.progress * 100).rounded())) %").monospacedDigit().frame(width: 38, alignment: .trailing)
            }
        }
    }

    private static func eta(_ text: String?) -> String? {
        guard let text, let date = (try? Date(text, strategy: .iso8601)) ?? Self.fractional(text) else { return nil }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    private static func fractional(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
