import AVFoundation
import BurrowUI
import PensieveCapture
import PensieveCore
import SwiftUI

/// The detail column while recording: the title and labels (still editable),
/// the camera or the meters in the middle, the marks at the side, and one
/// bar with the time, Markeer and Stop.
struct LiveRecordingView: View {
    @Environment(RecorderController.self) private var recorder
    @State private var title = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Titel", text: $title)
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                        .onSubmit { recorder.rename(title) }
                        .onAppear { title = recorder.title }
                        .help("Klik om de titel te wijzigen")
                    StageLabels()
                }
                Spacer()
            }
            .padding([.horizontal, .top], 24)
            HStack(alignment: .top, spacing: 20) {
                Group {
                    switch recorder.kind {
                    case .video:
                        if let session = recorder.cameraSession {
                            CameraPreview(session: session)
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    case .screen:
                        ContentUnavailableView(
                            "Pensieve neemt je scherm op", systemImage: "display",
                            description: Text("Met alles wat de Mac afspeelt\(recorder.screenWithMicrophone ? " en je microfoon" : "")."))
                    default:
                        VStack(spacing: 14) {
                            Meter(label: "Jij", decibels: recorder.levels.mic, warning: recorder.levels.micDead ? "Geen geluid: mag Pensieve de microfoon gebruiken?" : nil)
                            Meter(label: "Mac", decibels: recorder.levels.call, warning: recorder.levels.callSilent ? "Stil: speelt de Mac het gesprek af?" : nil)
                        }
                        .frame(maxWidth: 420)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !recorder.marks.marks.isEmpty { StageMarks().frame(width: 220) }
            }
            .padding(24)
            ControlBar(title: title)
                .padding(.bottom, 20)
        }
    }
}

private struct StageLabels: View {
    @Environment(PensieveModel.self) private var model
    @Environment(RecorderController.self) private var recorder

    var body: some View {
        @Bindable var recorder = recorder
        HStack(spacing: 6) {
            ForEach(recorder.labels, id: \.self) { label in
                Text(label)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .foregroundStyle(.tint)
                    .overlay(Capsule().strokeBorder(.tint.opacity(0.6)))
            }
            Menu {
                ForEach(model.labels) { label in
                    Toggle(label.name, isOn: Binding(get: { recorder.labels.contains(label.name) }, set: { on in
                        if on { recorder.labels.append(label.name) } else { recorder.labels.removeAll { $0 == label.name } }
                    }))
                }
                if model.labels.isEmpty { Text("Nog geen labels") }
            } label: {
                Label("Label", systemImage: "plus").labelStyle(.titleAndIcon).font(.caption)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
        }
    }
}

/// The moments marked so far; a note can be typed beside each.
private struct StageMarks: View {
    @Environment(RecorderController.self) private var recorder

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gemarkeerd").font(.headline)
            ForEach(Array(recorder.marks.marks.enumerated()), id: \.offset) { index, mark in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(stamp(mark.at)).monospacedDigit().foregroundStyle(.tint)
                    TextField("Notitie", text: Binding(get: { mark.note ?? "" }, set: { recorder.setNote($0, ofMark: index) }))
                        .textFieldStyle(.plain)
                }
                Divider()
            }
            Text("Stop zet de opname in iCloud Drive en stuurt het geluid naar Dobby.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// One bar: the time, the level, Markeer and Stop.
private struct ControlBar: View {
    @Environment(RecorderController.self) private var recorder
    let title: String

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Circle().fill(BurrowColor.danger).frame(width: 9, height: 9)
                    .opacity(Int(recorder.elapsed) % 2 == 0 ? 1 : 0.35)
                Text(clock(recorder.elapsed)).font(.title2.weight(.medium)).monospacedDigit()
            }
            Button {
                recorder.mark()
            } label: {
                Label("Markeer", systemImage: "bookmark")
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .help("Markeer dit moment (⇧⌘M)")
            Button {
                recorder.rename(title)
                Task { await recorder.stop() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(BurrowColor.danger)
            .keyboardShortcut(".")
            .help("Stop de opname (⌘.)")
            .accessibilityIdentifier("pensieve.stop")
        }
        .controlSize(.large)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .modifier(Glass(shape: Capsule()))
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

struct Meter: View {
    let label: String
    let decibels: Double
    let warning: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption.weight(.semibold))
                Spacer()
                if let warning { Text(warning).font(.caption).foregroundStyle(BurrowColor.warning) }
            }
            ProgressView(value: max(0, min(1, (decibels + 60) / 60)))
                .tint(decibels > -6 ? BurrowColor.danger : BurrowColor.pensieve)
        }
    }
}

/// The menu bar popover: start or stop, the meters, and what is waiting.
struct MenuBarContent: View {
    @Environment(PensieveModel.self) private var model
    @Environment(RecorderController.self) private var recorder
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if recorder.isRecording {
                HStack {
                    Text(recorder.title).font(.headline).lineLimit(1)
                    Spacer()
                    Text(clock(recorder.elapsed)).monospacedDigit()
                }
                Meter(label: "Jij", decibels: recorder.levels.mic, warning: nil)
                Meter(label: "Mac", decibels: recorder.levels.call, warning: nil)
                HStack {
                    Button { recorder.mark() } label: { Label("Markeer", systemImage: "bookmark").frame(maxWidth: .infinity) }
                    Button { Task { await recorder.stop() } } label: {
                        Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BurrowColor.danger)
                }
            } else {
                ForEach(RecordingKind.recordable, id: \.self) { kind in
                    Button {
                        openWindow(id: "main")
                        NSApp.activate()
                        record(kind, model: model, recorder: recorder)
                    } label: {
                        Label("Neem \(kind.title.lowercased()) op", systemImage: kind.symbol).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(model.connection == nil)
                }
                Text("Dicteren: houd ⌥ Spatie ingedrukt in elke app.").font(.caption).foregroundStyle(.secondary)
            }
            if !model.pending.isEmpty {
                Text("\(model.pending.count) wacht op upload").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.all.filter { [.compressing, .transcribing, .writingNotes].contains($0.status) }.prefix(3)) { r in
                HStack {
                    Text(r.title).lineLimit(1)
                    Spacer()
                    StatusPill(r.status.rawValue)
                }
                .font(.caption)
            }
            Divider()
            HStack {
                Button("Open Pensieve") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                SettingsLink { Text("Instellingen…") }
            }
            .buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 300)
    }
}
