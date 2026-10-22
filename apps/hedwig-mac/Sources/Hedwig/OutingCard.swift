import HedwigCore
import SwiftUI

/// One line above a mail about an outing (design v2): it is in Evenementen
/// with Bekijk, or Hedwig is unsure and offers Bewaar.
struct OutingCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            if let date = model.outing?.startsAt ?? model.outingSuggestion?.startsAt {
                OutingDateTile(date: date)
            } else {
                Image(systemName: "ticket")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.pink)
                    .frame(width: 40, height: 40)
                    .background(.pink.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            }
            if let outing = model.outing {
                saved(outing)
            } else if let suggestion = model.outingSuggestion {
                suggested(suggestion)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }

    private func saved(_ outing: Outing) -> some View {
        Group {
            VStack(alignment: .leading, spacing: 1) {
                Text(outing.title).font(.headline).lineLimit(1)
                Text(Self.line(outing.status()))
                    .font(.callout)
                    .foregroundStyle(outing.status().tone == .todo ? Color.orange : Color.secondary)
                    .lineLimit(1)
                    .help(Self.line(outing.status()))
            }
            Spacer()
            Button("Bekijk") { model.showOuting(outing.id) }
        }
    }

    private func suggested(_ s: OutingSuggestion) -> some View {
        Group {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(s.title ?? "Evenement")?").font(.headline).lineLimit(1)
                Text("Hedwig denkt dat dit om een evenement gaat").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Bewaar") { Task { await model.saveOuting() } }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
                .disabled(model.outingBusy || s.startsAt == nil || model.me?.can(.organize) != true)
                .help(s.startsAt == nil ? "Hedwig vond geen datum; voeg het zelf toe onder Evenementen" : "Bewaar onder Evenementen, met deze mail en de kaarten erbij")
        }
    }

    /// "Staat in Evenementen · nog doen: kaarten op naam zetten"
    static func line(_ status: OutingStatus) -> String {
        "Staat in Evenementen · \(status.text.lowercasedFirst)"
    }
}
