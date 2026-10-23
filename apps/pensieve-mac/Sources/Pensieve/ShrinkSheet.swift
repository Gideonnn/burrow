import BurrowUI
import PensieveCore
import PensieveMedia
import SwiftUI
import UniformTypeIdentifiers

/// "Verklein video" opens from the sidebar, the toolbar, a row and the menu.
@MainActor
@Observable
final class ShrinkRequest {
    static let shared = ShrinkRequest()

    struct Source: Identifiable {
        let url: URL
        var id: URL { url }
    }

    var source: Source?

    func open(_ url: URL) { source = Source(url: url) }

    /// Any video on this Mac, an iPhone `.mov` too.
    func choose() {
        guard let url = pickVideo() else { return }
        open(url)
    }
}

@MainActor
private func pickVideo() -> URL? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.movie]
    panel.message = "Kies de video die kleiner moet"
    panel.prompt = "Kies"
    return panel.runModal() == .OK ? panel.url : nil
}

/// Three qualities with their estimated size, and an optional limit such as
/// a school's 50 MB. The original stays; the small one lands beside it.
struct ShrinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var source: URL
    @State private var video: VideoSource?
    @State private var limit: Limit = .none
    @State private var customMB = 20
    @State private var quality: ShrinkQuality = .normal
    @State private var progress: Double?
    @State private var outcome: Shrinker.Outcome?
    @State private var failure: String?
    @State private var job: Task<Void, Never>?
    private let shrink = VideoShrink()

    enum Limit: Hashable {
        case none, mb(Int), custom
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Verklein video").font(.title3.weight(.semibold))
                Text("Voor inleveren op school, mailen of uploaden. Het origineel blijft staan.")
                    .foregroundStyle(.secondary)
            }
            Form {
                Section {
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: source.path)).resizable().frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.lastPathComponent).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                            Text(describe(video)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Kies andere…") { if let url = pickVideo() { source = url } }
                            .disabled(progress != nil)
                    }
                }
                Section("Maximaal toegestaan") {
                    Picker("Maximaal toegestaan", selection: $limit) {
                        Text("Geen limiet").tag(Limit.none)
                        Text("25 MB").tag(Limit.mb(25))
                        Text("50 MB").tag(Limit.mb(50))
                        Text("100 MB").tag(Limit.mb(100))
                        Text("Anders…").tag(Limit.custom)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if limit == .custom {
                        TextField("Megabyte", value: $customMB, format: .number)
                    }
                }
                Section("Kwaliteit") {
                    ForEach(options, id: \.quality) { option in
                        QualityRow(option: option, chosen: quality == option.quality)
                            .contentShape(Rectangle())
                            .onTapGesture { if option.fits { quality = option.quality } }
                            .opacity(option.fits ? 1 : 0.45)
                    }
                }
                Section {
                    footnote.font(.callout).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: limit == .custom ? 560 : 520)
            .disabled(progress != nil)
            HStack {
                if let progress {
                    ProgressView(value: progress).frame(width: 160)
                    Text("\(Int(progress * 100))%").monospacedDigit().foregroundStyle(.secondary)
                } else if let seconds = video?.seconds {
                    Text("± \(max(1, Int(seconds / 360))) minuut op deze Mac").foregroundStyle(.secondary)
                }
                Spacer()
                if case .shrunk(let result) = outcome {
                    Button("Toon in Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.output]) }
                    Button("Klaar") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Annuleer", role: .cancel) {
                        job?.cancel()
                        dismiss()
                    }
                    Button {
                        start()
                    } label: {
                        Label("Verklein", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(video == nil || progress != nil || !(options.first { $0.quality == quality }?.fits ?? false))
                }
            }
            .font(.callout)
        }
        .padding(20)
        .frame(width: 560)
        .task(id: source) {
            video = nil
            outcome = nil
            failure = nil
            do {
                video = try await shrink.options(for: source).source
            } catch {
                failure = "Pensieve kan deze video niet lezen."
            }
        }
        .onChange(of: limitBytes) { pickFitting() }
    }

    private var limitBytes: Int64? {
        switch limit {
        case .none: nil
        case .mb(let mb): Int64(mb) * 1_000_000
        case .custom: Int64(max(1, customMB)) * 1_000_000
        }
    }

    private var options: [ShrinkOption] {
        guard let video else { return [] }
        return ShrinkPlanner.options(source: video, limit: limitBytes)
    }

    /// With a limit, the best quality that fits.
    private func pickFitting() {
        if options.first(where: { $0.quality == quality })?.fits == false, let best = options.first(where: \.fits) {
            quality = best.quality
        }
    }

    @ViewBuilder private var footnote: some View {
        if let failure {
            Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(BurrowColor.danger)
        } else if case .shrunk(let result) = outcome {
            Label("Klaar: \(result.output.lastPathComponent), \(bytes(result.bytes)).", systemImage: "checkmark.circle")
        } else if case .alreadySmall(let size) = outcome {
            Label("De video is al \(bytes(size)); kleiner maken levert niets op.", systemImage: "checkmark.circle")
        } else {
            let height = options.first { $0.quality == quality }?.settings.height ?? quality.profile.height
            Label {
                Text("Opgeslagen naast het origineel als \(Text(VideoShrink.output(for: source, height: height).lastPathComponent).monospaced()). Het geluid blijft goed verstaanbaar in alle drie.")
            } icon: {
                Image(systemName: "sparkles")
            }
        }
    }

    private func start() {
        let source = source, quality = quality, limit = limitBytes
        progress = 0
        failure = nil
        job = Task {
            do {
                outcome = try await shrink.shrink(source, quality: quality, limit: limit) { fraction in
                    Task { @MainActor in progress = fraction }
                }
            } catch is CancellationError {
            } catch {
                failure = error.localizedDescription
            }
            progress = nil
        }
    }

    private func describe(_ video: VideoSource?) -> String {
        guard let video else { return failure == nil ? "Bezig met lezen…" : "" }
        return [clock(video.seconds), "\(video.shortSide)p", bytes(video.bytes)].joined(separator: " · ")
    }
}

private struct QualityRow: View {
    let option: ShrinkOption
    let chosen: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).fontWeight(.semibold) + Text(" · \(option.settings.height)p").foregroundStyle(.secondary)
                    if option.quality == .normal {
                        Text("Aanbevolen")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .foregroundStyle(.tint)
                            .background(.tint.opacity(0.14), in: Capsule())
                    }
                }
                Text(option.fits ? hint : "Te groot voor de limiet").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("± \(bytes(option.estimatedBytes))").fontWeight(.semibold).monospacedDigit()
                Text("\(bytes(option.bytesPerMinute)) per minuut").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var name: String {
        switch option.quality {
        case .high: "Hoog"
        case .normal: "Normaal"
        case .small: "Klein"
        }
    }

    private var hint: String {
        switch option.quality {
        case .high: "Scherp, ook op een digibord"
        case .normal: "Goed op een laptop, past bij de meeste opdrachten"
        case .small: "Kleinst, nog goed te volgen; tekst op dia's wordt wat zacht"
        }
    }
}
