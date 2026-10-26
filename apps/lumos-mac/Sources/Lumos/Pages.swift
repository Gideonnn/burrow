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
