import AppKit
import BurrowUI
import HogsmeadeCore
import HogsmeadeUI
import SwiftUI

/// Wijzig: what, when and where, and the notes. Saves only what changed.
struct EditOutingSheet: View {
    @Environment(OutingsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let outing: Outing
    @State private var draft: OutingDraft

    init(outing: Outing) {
        self.outing = outing
        _draft = State(initialValue: OutingDraft(outing))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Wat", text: $draft.title)
                    TextField("Soort", text: $draft.kind, prompt: Text("concert, theater, feest…"))
                }
                Section {
                    DatePicker("Begint", selection: $draft.startsAt)
                    Toggle("Deuren open", isOn: $draft.hasDoors)
                    if draft.hasDoors {
                        DatePicker("Deuren om", selection: $draft.doorsAt, displayedComponents: .hourAndMinute)
                    }
                    Toggle("Einde bekend", isOn: $draft.hasEnd)
                    if draft.hasEnd {
                        DatePicker("Einde", selection: $draft.endsAt)
                    }
                }
                Section {
                    TextField("Zaal", text: $draft.venue, prompt: Text("Zaal of plaats"))
                    TextField("Adres", text: $draft.address, prompt: Text("Straat en plaats"))
                }
                Section("Notities") {
                    TextField("Notities", text: $draft.notes, prompt: Text("Waar we afspreken, wie rijdt"), axis: .vertical)
                        .labelsHidden()
                        .lineLimit(3...8)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Annuleer") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Bewaar") {
                    let patch = draft.patch(against: outing)
                    dismiss()
                    if !patch.isEmpty { Task { await model.update(outing.id, patch) } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(minWidth: 460, idealWidth: 500, minHeight: 520)
    }
}

/// A picture for the outing: one Hedwig found, a file, a pasted one, or none.
struct PicturePickerSheet: View {
    @Environment(OutingsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let outing: Outing
    @State private var options: [OutingImageOption]?
    @State private var chosen: Choice?
    @State private var problem: String?

    enum Choice: Hashable { case option(OutingImageOption), none }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Afbeelding voor \(outing.title)").font(.title3.weight(.semibold)).lineLimit(1)
            Text(intro).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if options == nil {
                ProgressView().frame(maxWidth: .infinity, minHeight: 100)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 3), spacing: 8) {
                    ForEach(options ?? []) { option in
                        OptionTile(outing: outing, option: option, chosen: chosen == .option(option)) { chosen = .option(option) }
                    }
                    Tile(chosen: chosen == Choice.none, choose: { chosen = Choice.none }) {
                        OutingArt(outing: outing, symbolSize: 24)
                    } label: {
                        Text("Geen").font(.callout.weight(.semibold))
                        Text("kleuren bij de titel").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(BurrowColor.warning)
            }
            HStack {
                Button("Kies een bestand…", action: pickFile)
                Button("Plak") { Task { await set(NSPasteboard.general.pastedContents) } }
                    .help("Plak een afbeelding of een link naar een website (⌘V)")
                Spacer()
                Button("Annuleer") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Gebruik") { use() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen == nil || model.pictureBusy.contains(outing.id))
            }
        }
        .padding(20)
        .frame(width: 540)
        .onPasteCommand(of: [.image, .png, .tiff, .fileURL, .url]) { _ in
            Task { await set(NSPasteboard.general.pastedContents) }
        }
        .task { options = await model.pictureOptions(for: outing.id) }
        .onChange(of: model.error) {
            // An alert cannot show over this sheet; say it here instead.
            if let error = model.error {
                problem = error
                model.error = nil
            }
        }
    }

    private var intro: String {
        if options?.isEmpty == true {
            return "Hedwig vond niets in de mail of op de website. Kies of plak je eigen afbeelding, of houd de kleuren."
        }
        return "Hedwig vond deze. Kies er een, of kies of plak je eigen afbeelding."
    }

    private func use() {
        guard let chosen else { return }
        Task {
            switch chosen {
            case .option(let option): await model.choosePicture(option, for: outing.id)
            case .none: if outing.image != nil { await model.removePicture(from: outing.id) }
            }
            if problem == nil { dismiss() }
        }
    }

    private func set(_ contents: PastedContents) async {
        problem = nil
        await model.setPicture(contents, for: outing.id)
        if problem == nil { dismiss() }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Kies een afbeelding voor \(outing.title)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await set(PastedContents(fileURLs: [url])) }
    }
}

private struct OptionTile: View {
    @Environment(OutingsModel.self) private var model
    let outing: Outing
    let option: OutingImageOption
    let chosen: Bool
    let choose: () -> Void
    @State private var picture: OutingPicture?
    @State private var loading = true

    var body: some View {
        Tile(chosen: chosen, choose: choose) {
            if let picture {
                picture.swiftUI.resizable().scaledToFill()
            } else if loading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        } label: {
            Text(option.source == .mail ? "Uit de mail" : "Van de website").font(.callout.weight(.semibold))
            Text(picture.map { "\($0.width) × \($0.height)" } ?? " ").font(.caption).foregroundStyle(.secondary)
        }
        .task {
            picture = await model.pictureOption(option, of: outing.id)
            loading = false
        }
    }
}

private struct Tile<Art: View, Caption: View>: View {
    let chosen: Bool
    let choose: () -> Void
    @ViewBuilder let art: () -> Art
    @ViewBuilder let label: () -> Caption

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 6) {
                Rectangle().fill(.quaternary)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay { art() }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 0) { label() }.foregroundStyle(.primary)
            }
            .padding(4)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.tint, lineWidth: 2).opacity(chosen ? 1 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// A linked mail, to read without leaving Hogsmeade.
struct MailSheet: View {
    @Environment(OutingsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let mail: OutingMail
    @State private var detail: LinkedMail?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(detail?.subject ?? mail.subject ?? "(zonder onderwerp)").font(.title3.weight(.semibold)).textSelection(.enabled)
                Text([(detail?.from ?? mail.from)?.display, OutingFormat.date(mail.receivedAt)].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()
            Group {
                if let detail {
                    ScrollView {
                        Text(detail.bodyText?.nilIfBlank ?? detail.snippet)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                    }
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("Deze mail kan Hogsmeade niet lezen", systemImage: "envelope.badge.shield.half.filled")
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            HStack {
                Spacer()
                Button("Klaar") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(minWidth: 520, idealWidth: 620, minHeight: 420, idealHeight: 600)
        .task {
            detail = await model.mail(mail.id)
            loading = false
        }
    }
}

private extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
