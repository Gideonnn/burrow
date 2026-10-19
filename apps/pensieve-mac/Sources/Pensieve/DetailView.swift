import AVKit
import BurrowUI
import PensieveCore
import SwiftUI

/// One recording: who, when and who may see it; where the workers are with
/// it; then the notes, the transcript and the audio.
struct RecordingDetailView: View {
    @Environment(PensieveModel.self) private var model
    let detail: RecordingDetail
    @State private var tab = "notes"
    @State private var renaming = false
    @State private var newTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 12)
            if detail.status != .done { PipelineCard(detail: detail).padding(.horizontal, 24).padding(.bottom, 12) }
            Picker("", selection: $tab) {
                Text("Notulen").tag("notes")
                Text("Transcript").tag("transcript")
                Text("Audio").tag("audio")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
            .padding(.horizontal, 24)
            .accessibilityIdentifier("pensieve.tabs")
            Divider().padding(.top, 12)
            ScrollView {
                Group {
                    switch tab {
                    case "transcript": TranscriptView(text: detail.transcript)
                    case "audio": AudioView(detail: detail)
                    default: NotesView(detail: detail)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if detail.mine { ShareMenu(detail: detail) }
                Menu {
                    if detail.mine {
                        Button("Wijzig titel…") {
                            newTitle = detail.title
                            renaming = true
                        }
                        Button("Schrijf notulen opnieuw") { Task { await model.redo(detail.id, step: "notes") } }
                            .disabled(!detail.hasTranscript)
                        Button("Transcribeer opnieuw") { Task { await model.redo(detail.id, step: "transcript") } }
                        Divider()
                        Button("Verwijder…", role: .destructive) { confirmDelete() }
                            .accessibilityIdentifier("pensieve.approve.delete")
                    }
                } label: {
                    Label("Meer", systemImage: "ellipsis.circle")
                }
            }
        }
        .alert("Titel", isPresented: $renaming) {
            TextField("Titel", text: $newTitle)
            Button("Bewaar") { Task { await model.rename(detail.id, to: newTitle) } }
            Button("Annuleer", role: .cancel) {}
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(detail.title).font(.title2.weight(.semibold)).textSelection(.enabled)
            HStack(spacing: 8) {
                PersonBadge(detail.owner.name, size: 18)
                Text(detail.owner.name)
                Text("·").foregroundStyle(.tertiary)
                Text(detail.startedAt.formatted(date: .abbreviated, time: .shortened))
                if let seconds = detail.durationSeconds {
                    Text("·").foregroundStyle(.tertiary)
                    Text(clock(seconds)).monospacedDigit()
                }
                Text("·").foregroundStyle(.tertiary)
                privacy
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var privacy: some View {
        if !detail.mine {
            Label("Gedeeld door \(detail.owner.name)", systemImage: "person.2")
        } else if detail.sharedWith.isEmpty {
            Label("Alleen jij", systemImage: "lock")
        } else {
            Label("Gedeeld met \(detail.sharedWith.map(\.name).joined(separator: ", "))", systemImage: "person.2")
        }
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = "‘\(detail.title)’ verwijderen?"
        alert.informativeText = "De audio, het transcript en de notulen verdwijnen van Dobby. Een kopie in iCloud Drive blijft staan."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Annuleer")
        alert.addButton(withTitle: "Verwijder")
        if alert.runModal() == .alertSecondButtonReturn {
            Task { await model.delete(detail.id) }
        }
    }
}

struct ShareMenu: View {
    @Environment(PensieveModel.self) private var model
    let detail: RecordingDetail

    var body: some View {
        Menu {
            ForEach(model.others) { person in
                let shared = detail.sharedWith.contains { $0.id == person.id }
                Button(shared ? "Stop met delen met \(person.name)" : "Deel met \(person.name)") {
                    Task {
                        if shared { await model.unshare(detail.id, from: person.id) } else { await model.share(detail.id, with: person.id) }
                    }
                }
            }
            if model.others.isEmpty { Text("Er is niemand anders in het huishouden") }
        } label: {
            Label("Deel", systemImage: "person.badge.plus")
        }
        .accessibilityIdentifier("pensieve.approve.share")
    }
}

/// Where the workers are with this recording: compressing, transcribing,
/// writing the notes, or why it stopped.
struct PipelineCard: View {
    @Environment(PensieveModel.self) private var model
    let detail: RecordingDetail

    private let steps: [(RecordingStatus, String)] = [
        (.compressing, "Comprimeren"), (.transcribing, "Transcriberen"), (.writingNotes, "Notulen schrijven"),
    ]

    /// The step under way, or for a failed recording the one that failed.
    private var current: Int {
        if detail.status == .failed {
            return detail.audioBytes == nil ? 0 : detail.hasTranscript ? 2 : 1
        }
        return steps.firstIndex { $0.0 == detail.status } ?? steps.count
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            PersonBadge(current == 2 ? "Winky" : "Dobby", size: 30)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(steps, id: \.0) { status, label in
                        let index = steps.firstIndex { $0.0 == status }!
                        Text(label)
                            .font(.caption.weight(index == current ? .semibold : .regular))
                            .foregroundStyle(
                                index < current ? BurrowColor.success
                                    : index == current ? (detail.status == .failed ? BurrowColor.danger : BurrowColor.info)
                                    : .secondary)
                        if index < steps.count - 1 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    }
                }
                if detail.status == .failed {
                    Text(detail.error ?? "Mislukt").font(.callout).foregroundStyle(BurrowColor.danger)
                } else {
                    Text(detail.status == .writingNotes ? "Winky luistert terug en schrijft de notulen." : "Dobby is ermee bezig.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if detail.status == .failed, detail.mine {
                Button("Probeer opnieuw") {
                    Task { await model.redo(detail.id, step: detail.hasTranscript ? "notes" : "transcript") }
                }
            } else if detail.status != .failed {
                ProgressView().controlSize(.small)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(BurrowColor.linen))
    }
}

struct NotesView: View {
    let detail: RecordingDetail

    var body: some View {
        if let notes = detail.notes {
            VStack(alignment: .leading, spacing: 22) {
                section("Samenvatting") { Text(notes.summary).textSelection(.enabled) }
                if !notes.decisions.isEmpty {
                    section("Besluiten") {
                        ForEach(notes.decisions, id: \.self) { Label($0, systemImage: "checkmark.seal").labelStyle(Bullet()) }
                    }
                }
                if !notes.actions.isEmpty {
                    section("Actiepunten") {
                        ForEach(notes.actions, id: \.self) { action in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "square").foregroundStyle(.secondary)
                                Text(action.text)
                                Spacer()
                                if let owner = action.owner { PersonBadge(owner, size: 16); Text(owner).foregroundStyle(.secondary) }
                                if let due = action.due { Text(due).foregroundStyle(.secondary) }
                            }
                            .font(.body)
                        }
                    }
                }
                if !notes.openQuestions.isEmpty {
                    section("Open vragen") {
                        ForEach(notes.openQuestions, id: \.self) { Label($0, systemImage: "questionmark.circle").labelStyle(Bullet()) }
                    }
                }
            }
        } else if let markdown = detail.notesMarkdown {
            Text((try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(markdown))
                .textSelection(.enabled)
        } else {
            ContentUnavailableView("Nog geen notulen", systemImage: "doc.text", description: Text(detail.status == .failed ? "Zie hierboven wat er misging." : "Winky schrijft ze zodra het transcript klaar is."))
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }
}

struct Bullet: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.foregroundStyle(.secondary)
            configuration.title.textSelection(.enabled)
        }
    }
}

struct TranscriptView: View {
    let text: String?

    var body: some View {
        if let text, !text.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(text.split(separator: "\n").enumerated()), id: \.offset) { _, line in
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2, parts[0].count <= 12 {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(String(parts[0])).font(.callout.weight(.semibold)).frame(width: 60, alignment: .leading)
                            Text(String(parts[1]).trimmingCharacters(in: .whitespaces)).textSelection(.enabled)
                        }
                    } else {
                        Text(String(line)).textSelection(.enabled)
                    }
                }
            }
        } else {
            ContentUnavailableView("Nog geen transcript", systemImage: "text.alignleft")
        }
    }
}

/// Streams the audio from Dobby. AVPlayer cannot send the key itself, so the
/// file is fetched once into a temporary file and played from there.
struct AudioView: View {
    @Environment(PensieveModel.self) private var model
    let detail: RecordingDetail
    @State private var player: AVPlayer?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let player {
                VideoPlayer(player: player).frame(height: 60)
            } else if detail.audioBytes == nil {
                Text("De audio wordt nog gecomprimeerd.").foregroundStyle(.secondary)
            } else {
                Button(loading ? "Laden…" : "Laad de audio (\(ByteCountFormatter.string(fromByteCount: Int64(detail.audioBytes ?? 0), countStyle: .file)))") {
                    Task { await load() }
                }
                .disabled(loading)
            }
        }
        .onDisappear { player?.pause() }
    }

    private func load() async {
        guard let api = model.api else { return }
        loading = true
        defer { loading = false }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pensieve-\(detail.id).m4a")
        do {
            if !FileManager.default.fileExists(atPath: file.path) { try await api.downloadAudio(detail.id, to: file) }
            player = AVPlayer(url: file)
        } catch {
            model.error = error.localizedDescription
        }
    }
}
