import BurrowUI
import LumosCore
import LumosUI
import SwiftUI

/// A person: who they are and everything they made, films and series
/// apart, each with the part they had. A click opens the title's page on
/// top; Esc comes back here.
struct PersonPage: View {
    @Environment(LumosModel.self) private var model
    let id: String
    var focused: FocusState<LumosModel.Focus?>.Binding
    @State private var fullBiography = false

    var body: some View {
        ScrollView {
            if let page = model.personPage, page.id == id {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 22) {
                        CachedImage(url: page.person?.photo.flatMap(URL.init(string:)), maxPixels: 342) {
                            ZStack {
                                TileColours(page.name).start
                                Image(systemName: "person.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.7))
                            }
                        }
                        .frame(width: 150, height: 225)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 8) {
                            Text(page.name).font(.largeTitle).bold()
                            if let person = page.person {
                                Text(facts(person)).font(.callout).foregroundStyle(.secondary)
                                if let biography = person.biography {
                                    Text(biography)
                                        .font(.body)
                                        .lineSpacing(3)
                                        .lineLimit(fullBiography ? nil : 6)
                                        .textSelection(.enabled)
                                    if biography.count > 500 {
                                        Button(fullBiography ? "Minder" : "Meer") { fullBiography.toggle() }.buttonStyle(.borderless).font(.callout)
                                    }
                                }
                            } else if model.personLoading {
                                ProgressView().controlSize(.small)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(EdgeInsets(top: 20, leading: 24, bottom: 8, trailing: 24))
                    let movies = page.titles.filter { $0.mediaType == .movie }
                    let series = page.titles.filter { $0.mediaType == .tv }
                    VStack(alignment: .leading, spacing: 22) {
                        if !movies.isEmpty {
                            GridSection(row: TitleRow(key: "person-movies", title: "Films", subtitle: "\(movies.count)", style: .poster, items: movies, empty: nil))
                        }
                        if !series.isEmpty {
                            GridSection(row: TitleRow(key: "person-series", title: "Series", subtitle: "\(series.count)", style: .poster, items: series, empty: nil))
                        }
                        if page.titles.isEmpty, !model.personLoading {
                            ContentUnavailableView("Niets gevonden van \(page.name)", systemImage: "person.crop.rectangle")
                        }
                    }
                    .padding(.vertical, 16)
                }
            } else {
                ProgressView().padding(40)
            }
        }
        .navigationTitle(model.personPage?.name ?? "Persoon")
        .focusable()
        .focused(focused, equals: .inspector)
        .focusEffectDisabled()
        .onExitCommand { model.escape() }
        .onKeyPress(.escape) { model.escape(); return .handled }
    }

    private func facts(_ person: PersonDetail) -> String {
        var parts: [String] = []
        if let known = person.known {
            parts.append(["Acting": "Acteur", "Directing": "Regisseur", "Writing": "Schrijver", "Production": "Producent", "Sound": "Componist"][known] ?? known)
        }
        if let born = person.birthday {
            parts.append("geboren \(born)\(person.placeOfBirth.map { " in \($0)" } ?? "")")
        }
        if let died = person.deathday { parts.append("overleden \(died)") }
        return parts.joined(separator: " · ")
    }
}
