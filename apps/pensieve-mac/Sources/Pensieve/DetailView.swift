import AVKit
import BurrowUI
import PensieveCore
import SwiftUI

/// One recording in a single column: what it is, the player with the
/// timeline and the transcript that follows it, then the summary, the marks
/// and the files in iCloud.
struct RecordingDetailView: View {
    @Environment(PensieveModel.self) private var model
    let detail: RecordingDetail
    @State private var playback = Playback()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DetailHeader(detail: detail)
                PlayerSection(detail: detail, playback: playback)
                if !detail.marks.isEmpty || detail.segments?.isEmpty == false {
                    Timeline(detail: detail, playback: playback)
                }
                if let segments = detail.segments, !segments.isEmpty {
                    FollowingTranscript(segments: segments, playback: playback)
                } else if let text = detail.transcript, !text.isEmpty {
                    PlainTranscript(text: text)
                }
                if detail.status == .stored && !detail.hasTranscript {
                    if detail.mine { TranscribeCard(detail: detail) }
                } else if detail.status != .done {
                    PipelineCard(detail: detail)
                }
                NotesSection(detail: detail, playback: playback)
                if !detail.marks.isEmpty {
                    DetailSection("Gemarkeerd tijdens het opnemen") {
                        ForEach(Array(detail.marks.enumerated()), id: \.offset) { _, mark in
                            Moment(at: mark.at, text: mark.note ?? "Gemarkeerd", playback: playback)
                        }
                    }
                }
                if let folder = model.folder(of: detail.id) { FilesSection(folder: folder) }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onDisappear { playback.stop() }
    }
}

private struct DetailHeader: View {
    @Environment(PensieveModel.self) private var model
    let detail: RecordingDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(detail.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                Spacer()
                Text(detail.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 5) {
                Image(systemName: detail.kind.symbol).imageScale(.small)
                Text(([detail.durationSeconds.map(clock), size] + [detail.mine ? nil : "van \(detail.owner.name)"])
                    .compactMap { $0 }.joined(separator: " · "))
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            LabelPills(detail: detail).padding(.top, 2)
        }
    }

    private var size: String? {
        if let video = model.video(of: detail.id),
           let count = try? FileManager.default.attributesOfItem(atPath: video.path)[.size] as? Int64 {
            return bytes(count)
        }
        return detail.audioBytes.map { bytes(Int64($0)) }
    }
}

/// The labels as small pills, and a menu to add or remove them.
private struct LabelPills: View {
    @Environment(PensieveModel.self) private var model
    let detail: RecordingDetail
    @State private var adding = false
    @State private var newLabel = ""

    var body: some View {
        HStack(spacing: 6) {
            ForEach(detail.labels, id: \.self) { label in
                Text(label)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .foregroundStyle(.tint)
                    .overlay(Capsule().strokeBorder(.tint.opacity(0.6)))
            }
            Menu {
                ForEach(model.labels) { label in
                    Toggle(label.name, isOn: Binding(get: { detail.labels.contains(label.name) }, set: { on in
                        let labels = on ? detail.labels + [label.name] : detail.labels.filter { $0 != label.name }
                        Task { await model.setLabels(detail.id, labels) }
                    }))
                }
                if !model.labels.isEmpty { Divider() }
                Button("Nieuw label…") {
                    newLabel = ""
                    adding = true
                }
            } label: {
                Label("Label", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
        }
        .alert("Nieuw label", isPresented: $adding) {
            TextField("Naam", text: $newLabel)
            Button("Voeg toe") {
                let name = newLabel.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { Task { await model.setLabels(detail.id, detail.labels + [name]) } }
            }
            Button("Annuleer", role: .cancel) {}
        }
    }
}

// MARK: Playing

/// The player of the open recording and where it is, for the timeline and
/// the transcript.
@MainActor
@Observable
final class Playback {
    private(set) var player: AVPlayer?
    private(set) var time: Double = 0
    private(set) var loading = false
    @ObservationIgnored private var observer: Any?

    func load(_ url: URL) {
        stop()
        let player = AVPlayer(url: url)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.time = time.seconds }
        }
        self.player = player
    }

    /// Calls and dictations play from the folder in iCloud, else from Dobby.
    func loadAudio(_ detail: RecordingDetail, model: PensieveModel) async {
        if let folder = model.folder(of: detail.id) {
            let audio = folder.appendingPathComponent(Naming.audio)
            if FileManager.default.fileExists(atPath: audio.path) { return load(audio) }
        }
        guard let api = model.api else { return }
        loading = true
        defer { loading = false }
        // AVPlayer cannot send the key itself, so the file is fetched once.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pensieve-\(detail.id).m4a")
        do {
            if !FileManager.default.fileExists(atPath: file.path) { try await api.downloadAudio(detail.id, to: file) }
            load(file)
        } catch {
            model.error = error.localizedDescription
        }
    }

    func seek(_ seconds: Double) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        time = seconds
        if player.timeControlStatus != .playing { player.play() }
    }

    func stop() {
        player?.pause()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player = nil
    }
}

private struct PlayerSection: View {
    @Environment(PensieveModel.self) private var model
    let detail: RecordingDetail
    let playback: Playback

    var body: some View {
        Group {
            if detail.kind.hasVideo {
                if let player = playback.player {
                    PlayerView(player: player, style: .floating)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    ContentUnavailableView(
                        "De video staat niet op deze Mac", systemImage: "video.slash",
                        description: Text("Hij staat in iCloud Drive › Pensieve zodra hij daar is gekopieerd."))
                        .frame(maxWidth: .infinity, minHeight: 200)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                }
            } else if let player = playback.player {
                PlayerView(player: player, style: .inline)
                    .frame(height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if detail.audioBytes == nil {
                Text("Het geluid wordt nog gecomprimeerd.").foregroundStyle(.secondary)
            } else {
                Button {
                    Task { await playback.loadAudio(detail, model: model) }
                } label: {
                    Label(playback.loading ? "Laden…" : "Speel af (\(bytes(Int64(detail.audioBytes ?? 0))))", systemImage: "play.fill")
                }
                .disabled(playback.loading)
            }
        }
        .task(id: detail.id) {
            if detail.kind.hasVideo {
                if let video = model.video(of: detail.id) { playback.load(video) }
            } else if model.folder(of: detail.id) != nil {
                await playback.loadAudio(detail, model: model)
            }
        }
    }
}

/// AppKit's player: SwiftUI's VideoPlayer does not load in a plain Swift
/// package executable.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    let style: AVPlayerViewControlsStyle

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = style
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// Who speaks when, the marks, and where the player is; a click jumps there.
private struct Timeline: View {
    let detail: RecordingDetail
    let playback: Playback

    var body: some View {
        let total = max(detail.durationSeconds ?? detail.segments?.last?.end ?? 1, 1)
        let speakers = Speakers(detail.segments ?? [])
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6))
                    if detail.segments?.isEmpty != false {
                        Text("Wie wanneer praat verschijnt hier na het transcript.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .offset(x: 10, y: 21)
                    }
                    ForEach(Array((detail.segments ?? []).enumerated()), id: \.offset) { _, segment in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(speakers.color(segment.speaker).opacity(0.75))
                            .frame(width: max(1, (segment.end - segment.start) / total * width - 1), height: 10)
                            .offset(x: segment.start / total * width, y: 22)
                    }
                    ForEach(Array(detail.marks.enumerated()), id: \.offset) { _, mark in
                        Image(systemName: "bookmark.fill")
                            .font(.caption2)
                            .foregroundStyle(.pink)
                            .offset(x: mark.at / total * width - 4, y: 4)
                            .help(mark.note ?? stamp(mark.at))
                    }
                    Rectangle()
                        .fill(.primary)
                        .frame(width: 2)
                        .offset(x: min(width - 2, playback.time / total * width))
                }
                .contentShape(Rectangle())
                .onTapGesture { point in playback.seek(point.x / width * total) }
            }
            .frame(height: 40)
            if !speakers.names.isEmpty {
                HStack(spacing: 14) {
                    ForEach(speakers.names, id: \.self) { name in
                        HStack(spacing: 5) {
                            Circle().fill(speakers.color(name)).frame(width: 7, height: 7)
                            Text(name)
                        }
                    }
                    if !detail.marks.isEmpty {
                        Label("gemarkeerd", systemImage: "bookmark.fill").labelStyle(.titleAndIcon)
                    }
                    Spacer()
                    Text("\(stamp(playback.time)) / \(stamp(total))").monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// Speakers in order of first appearance, each with a colour.
struct Speakers {
    let names: [String]
    private static let palette: [Color] = [BurrowColor.pensieve, .orange, .purple, .blue, .pink, .brown]

    init(_ segments: [TranscriptSegment]) {
        var seen: [String] = []
        for segment in segments { if let s = segment.speaker, !seen.contains(s) { seen.append(s) } }
        names = seen
    }

    func color(_ speaker: String?) -> Color {
        guard let speaker, let index = names.firstIndex(of: speaker) else { return .secondary }
        return Self.palette[index % Self.palette.count]
    }
}

/// The transcript that scrolls along with the player; the current line stands out.
private struct FollowingTranscript: View {
    let segments: [TranscriptSegment]
    let playback: Playback

    var body: some View {
        let speakers = Speakers(segments)
        let current = segments.lastIndex { $0.start <= playback.time } ?? 0
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                if let speaker = segment.speaker {
                                    Text(speaker).foregroundStyle(speakers.color(speaker)).fontWeight(.semibold)
                                }
                                Text(stamp(segment.start)).monospacedDigit().foregroundStyle(.tertiary)
                            }
                            .font(.caption)
                            Text(segment.text)
                                .font(.title3)
                                .foregroundStyle(index == current ? .primary : index < current ? .tertiary : .secondary)
                                .textSelection(.enabled)
                        }
                        .id(index)
                        .contentShape(Rectangle())
                        .onTapGesture { playback.seek(segment.start) }
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 220)
            .onChange(of: current) {
                guard playback.player?.timeControlStatus == .playing else { return }
                withAnimation { proxy.scrollTo(current, anchor: .center) }
            }
        }
        .padding(.horizontal, 2)
    }
}

/// A transcript without timestamps: "Naam: tekst" per line.
private struct PlainTranscript: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        DetailSection("Transcript") {
            let lines = text.split(separator: "\n")
            ForEach(Array(lines.prefix(expanded ? lines.count : 6).enumerated()), id: \.offset) { _, line in
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2, parts[0].count <= 12 {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(String(parts[0])).font(.callout.weight(.semibold)).frame(width: 64, alignment: .leading)
                        Text(String(parts[1]).trimmingCharacters(in: .whitespaces)).textSelection(.enabled)
                    }
                } else {
                    Text(String(line)).textSelection(.enabled)
                }
            }
            if lines.count > 6 {
                Button(expanded ? "Toon minder" : "Toon het hele transcript") { expanded.toggle() }
                    .buttonStyle(.link)
            }
        }
    }
}

// MARK: Work

/// A video or screen recording without transcript: one button makes it.
private struct TranscribeCard: View {
    @Environment(PensieveModel.self) private var model
    let detail: RecordingDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Maak transcript en samenvatting").font(.headline)
            Text("Alleen het geluid wordt getranscribeerd, met sprekers, \(detail.kind == .screen ? "stappen" : "citaten") en ondertitels.")
                .foregroundStyle(.secondary)
            Button {
                Task { await model.requestTranscript(detail.id) }
            } label: {
                Label("Maak transcript", systemImage: "doc.text")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Where the workers are with this recording, or why it stopped.
struct PipelineCard: View {
    @Environment(PensieveModel.self) private var model
    let detail: RecordingDetail

    var body: some View {
        HStack(spacing: 12) {
            if detail.status == .failed {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(BurrowColor.danger)
            } else {
                ProgressView().controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(detail.status == .failed ? "Mislukt" : StatusPill.label(detail.status.rawValue)).font(.headline)
                Text(detail.status == .failed ? detail.error ?? "Er ging iets mis." : explanation)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if detail.status == .failed, detail.mine {
                Button("Probeer opnieuw") {
                    Task { await model.redo(detail.id, step: detail.hasTranscript ? "notes" : "transcript") }
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private var explanation: String {
        switch detail.status {
        case .compressing: "Dobby maakt het geluid kleiner."
        case .transcribing: "Dobby schrijft uit wat er gezegd is."
        case .writingNotes: "Kreacher luistert terug en schrijft de samenvatting."
        default: "Dobby is ermee bezig."
        }
    }
}

// MARK: Text

/// The summary as the kind has it: a meeting's decisions and actions, an
/// interview's quotes and chapters, a screen recording's steps.
private struct NotesSection: View {
    let detail: RecordingDetail
    let playback: Playback

    var body: some View {
        if let notes = detail.notes {
            VStack(alignment: .leading, spacing: 20) {
                DetailSection(notes.type == .interview ? "Kern" : "Samenvatting") {
                    Text(notes.summary).textSelection(.enabled)
                }
                if !notes.decisions.isEmpty {
                    DetailSection("Besluiten") {
                        ForEach(notes.decisions, id: \.self) { Bullet(text: $0, symbol: "checkmark.seal") }
                    }
                }
                if !notes.actions.isEmpty {
                    DetailSection("Actiepunten") {
                        ForEach(notes.actions, id: \.self) { action in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "square").foregroundStyle(.secondary)
                                Text(action.text).textSelection(.enabled)
                                Spacer()
                                Text([action.owner, action.due].compactMap { $0 }.joined(separator: " · "))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !notes.openQuestions.isEmpty {
                    DetailSection("Open vragen") {
                        ForEach(notes.openQuestions, id: \.self) { Bullet(text: $0, symbol: "questionmark.circle") }
                    }
                }
                if !notes.quotes.isEmpty {
                    DetailSection("Citaten") {
                        ForEach(notes.quotes, id: \.self) { quote in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("“\(quote.text)”").font(.title3).textSelection(.enabled)
                                HStack(spacing: 6) {
                                    if let speaker = quote.speaker { Text(speaker) }
                                    if let at = quote.at {
                                        Button(stamp(at)) { playback.seek(at) }.buttonStyle(.plain).foregroundStyle(.tint).monospacedDigit()
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !notes.chapters.isEmpty {
                    DetailSection("Hoofdstukken") {
                        ForEach(notes.chapters, id: \.self) { Moment(at: $0.at, text: $0.title, playback: playback) }
                    }
                }
                if !notes.steps.isEmpty {
                    DetailSection("Stappen") {
                        ForEach(Array(notes.steps.enumerated()), id: \.offset) { index, step in
                            Moment(at: step.at, text: "\(index + 1). \(step.text)", playback: playback)
                        }
                    }
                }
            }
        } else if let markdown = detail.notesMarkdown {
            DetailSection("Samenvatting") {
                Text((try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(markdown))
                    .textSelection(.enabled)
            }
        }
    }
}

struct DetailSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Bullet: View {
    let text: String
    let symbol: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(text).textSelection(.enabled)
        }
    }
}

/// A moment with its time; the time jumps the player there.
private struct Moment: View {
    let at: Double?
    let text: String
    let playback: Playback

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let at {
                Button(stamp(at)) { playback.seek(at) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .monospacedDigit()
                    .frame(width: 52, alignment: .leading)
            }
            Text(text).textSelection(.enabled)
        }
    }
}

/// What the recording's folder in iCloud Drive holds.
private struct FilesSection: View {
    let folder: URL

    var body: some View {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        DetailSection("In iCloud Drive") {
            VStack(spacing: 0) {
                ForEach(files, id: \.self) { file in
                    Button { NSWorkspace.shared.open(file) } label: {
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                                .resizable()
                                .frame(width: 18, height: 18)
                            Text(file.lastPathComponent)
                            Spacer()
                            Text(bytes(Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Toon in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                        ShareLink(item: file) { Text("Stuur…") }
                    }
                    if file != files.last { Divider() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            Button("Toon in Finder") { NSWorkspace.shared.open(folder) }
                .buttonStyle(.link)
                .font(.callout)
        }
    }
}
