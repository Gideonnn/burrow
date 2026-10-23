import HedwigCore
import SwiftUI

/// Under a message in Spam or Archief that the bot put there: its reason, and
/// the review that used to be the Gefilterd page.
struct ReviewLine: View {
    @Environment(AppModel.self) private var model
    let entry: FilteredEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(entry.reason, systemImage: "sparkles")
                .foregroundStyle(.secondary)
                .lineLimit(3)
            HStack {
                if entry.unsure { Tag(text: "Twijfel", color: .orange) }
                Spacer()
                Button("Klopt") { Task { await model.confirm(entry) } }
                    .foregroundStyle(.green)
                Button(restoreTitle(entry)) { Task { await model.restore(entry) } }
            }
            .buttonStyle(.borderless)
            .disabled(model.me?.can(.organize) != true)
        }
        .font(.caption)
        .padding(.leading, 16)
    }
}

/// Above an open message in Spam, or in Archief when the bot put it there.
struct ReviewBar: View {
    @Environment(AppModel.self) private var model
    let message: MessageDetail

    var body: some View {
        let entry = model.review(for: message.id)
        if entry != nil || message.folder == .spam {
            VStack(alignment: .leading, spacing: 8) {
                if let entry {
                    Label(
                        (entry.unsure ? "Twijfelgeval · " : "") + "\(entry.bot) zette dit in \(message.folder == .spam ? "Spam" : "Archief")",
                        systemImage: "checkmark.shield"
                    )
                    .font(.headline)
                    .foregroundStyle(entry.unsure ? .orange : .primary)
                    Text(entry.reason)
                }
                if message.folder == .spam {
                    Text("Blijft ongelezen en zonder externe afbeeldingen tot je het geen spam noemt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    if let entry {
                        Button("Klopt") { Task { await model.confirm(entry) } }
                        Button(restoreTitle(entry)) { Task { await model.restore(entry) } }
                    } else {
                        Button("Geen spam") { Task { await model.notSpam() } }
                    }
                }
                .disabled(model.me?.can(.organize) != true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private func restoreTitle(_ entry: FilteredEntry) -> String {
    entry.message.folder == .spam ? "Geen spam" : "Terug naar inbox"
}
