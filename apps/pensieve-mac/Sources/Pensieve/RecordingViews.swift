import BurrowUI
import PensieveCapture
import PensieveCore
import SwiftUI

/// Asks for a title and a microphone, then starts. Nothing leaves the Mac
/// until the recording stops.
struct NewRecordingSheet: View {
    @Environment(RecorderController.self) private var recorder
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""

    var body: some View {
        @Bindable var recorder = recorder
        VStack(alignment: .leading, spacing: 16) {
            Text("Nieuwe opname").font(.title3.weight(.semibold))
            Text("Pensieve neemt jouw microfoon op en alles wat de Mac afspeelt, dus ook de andere kant van een Zoom- of Teams-gesprek. Vraag de anderen of het goed is dat je opneemt.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Form {
                TextField("Titel", text: $title, prompt: Text("Bijvoorbeeld: Intake Studio Vos"))
                Picker("Microfoon", selection: $recorder.microphone) {
                    ForEach(recorder.microphones, id: \.uid) { Text($0.name).tag(Optional($0)) }
                }
            }
            .formStyle(.grouped)
            if let error = recorder.error {
                Text(error).font(.callout).foregroundStyle(BurrowColor.danger)
            }
            HStack {
                Spacer()
                Button("Annuleer", role: .cancel) { dismiss() }
                Button {
                    Task {
                        await recorder.start(title: title)
                        if recorder.isRecording { dismiss() }
                    }
                } label: {
                    Label("Start opname", systemImage: "record.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(BurrowColor.danger)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("pensieve.approve.record")
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            recorder.error = nil
            recorder.refreshMicrophones()
        }
    }
}

/// The detail column while recording: elapsed time, both meters, the title
/// (still editable) and the stop button.
struct LiveRecordingView: View {
    @Environment(RecorderController.self) private var recorder
    @State private var title = ""

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            HStack(spacing: 10) {
                Circle().fill(BurrowColor.danger).frame(width: 12, height: 12)
                    .opacity(Int(recorder.elapsed) % 2 == 0 ? 1 : 0.35)
                Text(clock(recorder.elapsed))
                    .font(.system(size: 48, weight: .light).monospacedDigit())
            }
            TextField("Titel", text: $title)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
                .onSubmit { recorder.rename(title) }
                .onAppear { title = recorder.title }
            VStack(spacing: 12) {
                Meter(label: "Microfoon", decibels: recorder.levels.mic, warning: recorder.levels.micDead ? "Geen geluid: mag Pensieve de microfoon gebruiken?" : nil)
                Meter(label: "Gesprek", decibels: recorder.levels.call, warning: recorder.levels.callSilent ? "Stil: speelt de Mac het gesprek af?" : nil)
            }
            .frame(width: 360)
            Button {
                recorder.rename(title)
                Task { await recorder.stop() }
            } label: {
                Label("Stop opname", systemImage: "stop.fill").frame(width: 200)
            }
            .buttonStyle(.borderedProminent)
            .tint(BurrowColor.danger)
            .controlSize(.large)
            .keyboardShortcut(".")
            .accessibilityIdentifier("pensieve.stop")
            Text("Alleen jij, tot je deelt. Bij stoppen gaat de opname naar Dobby.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
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
            GeometryReader { geometry in
                let level = max(0, min(1, (decibels + 60) / 60))
                ZStack(alignment: .leading) {
                    Capsule().fill(BurrowColor.hairline)
                    Capsule().fill(level > 0.9 ? BurrowColor.danger : BurrowColor.pensieve)
                        .frame(width: geometry.size.width * level)
                }
            }
            .frame(height: 6)
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
                Meter(label: "Microfoon", decibels: recorder.levels.mic, warning: nil)
                Meter(label: "Gesprek", decibels: recorder.levels.call, warning: nil)
                Button {
                    Task { await recorder.stop() }
                } label: {
                    Label("Stop opname", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(BurrowColor.danger)
            } else {
                Button {
                    openWindow(id: "main")
                    NSApp.activate()
                    NewRecordingRequest.shared.open = true
                } label: {
                    Label("Nieuwe opname…", systemImage: "record.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(BurrowColor.danger)
                .disabled(model.connection == nil)
            }
            if !model.pending.isEmpty {
                Text("\(model.pending.count) wacht op upload").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.recordings.filter { $0.status != .done && $0.status != .failed }.prefix(3)) { r in
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
