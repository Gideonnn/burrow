import AppKit
import BurrowUI
import PensieveCore
import SwiftUI

/// A small window above every app that never takes the focus from it.
final class FloatingPanel: NSPanel {
    init(movable: Bool, @ViewBuilder content: () -> some View) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = movable
        backgroundColor = .clear
        hasShadow = true
        let host = NSHostingView(rootView: content())
        host.sizingOptions = [.preferredContentSize]
        contentView = host
    }

    override var canBecomeKey: Bool { false }
}

// MARK: Dictation

/// The pill at the bottom of the screen while ⌥ Spatie is held, and what
/// happened to the text after.
@MainActor
final class DictationHUD {
    private var panel: FloatingPanel?
    private var hide: Task<Void, Never>?

    func show(_ state: DictationController.State) {
        hide?.cancel()
        if state == .idle { return close() }
        let panel = FloatingPanel(movable: false) { DictationPill(state: state) }
        self.panel?.orderOut(nil)
        self.panel = panel
        panel.layoutIfNeeded()
        if let screen = NSScreen.main {
            let size = panel.contentView?.fittingSize ?? .zero
            panel.setFrame(
                NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 80, width: size.width, height: size.height),
                display: true)
        }
        panel.orderFrontRegardless()
        switch state {
        case .pasted, .failed:
            hide = Task {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { close() }
            }
        default:
            break
        }
    }

    private func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct DictationPill: View {
    let state: DictationController.State

    var body: some View {
        HStack(spacing: 10) {
            icon
            text
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .modifier(Glass(shape: Capsule()))
        .padding(12)
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .listening:
            Image(systemName: "mic.fill")
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(BurrowColor.danger, in: Circle())
                .symbolEffect(.pulse)
        case .transcribing:
            ProgressView().controlSize(.small)
        case .pasted:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(BurrowColor.success)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(BurrowColor.warning)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder private var text: some View {
        switch state {
        case .listening:
            Text("Luistert · laat \(Text("⌥ Spatie").fontWeight(.semibold)) los om te plakken")
        case .transcribing:
            Text("Uitschrijven…")
        case .pasted(.pasted(let app)):
            Text(app.map { "Geplakt in \($0)" } ?? "Geplakt")
        case .pasted(.onClipboard):
            Text("Staat op het klembord: plak met ⌘V")
        case .failed(let reason):
            Text(reason).lineLimit(2)
        case .idle:
            EmptyView()
        }
    }
}

// MARK: Recording

/// While a call or the screen is recorded and Pensieve is in the background,
/// it shrinks to a bubble above every app: the inner ball is your voice, the
/// ring the other side. Drag it anywhere.
@MainActor
final class RecordingOrb {
    private var panel: FloatingPanel?
    private let recorder: RecorderController

    init(recorder: RecorderController) {
        self.recorder = recorder
    }

    func start() {
        Task { [weak self] in
            while !Task.isCancelled {
                self?.update()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func update() {
        let wanted = recorder.isRecording && recorder.kind != .video && !NSApp.isActive
        if wanted, panel == nil {
            let panel = FloatingPanel(movable: true) { OrbView().environment(recorder) }
            panel.layoutIfNeeded()
            if let screen = NSScreen.main {
                let size = panel.contentView?.fittingSize ?? .zero
                panel.setFrame(
                    NSRect(x: screen.visibleFrame.maxX - size.width - 24, y: screen.visibleFrame.maxY - size.height - 24,
                           width: size.width, height: size.height),
                    display: true)
            }
            panel.orderFrontRegardless()
            self.panel = panel
        } else if !wanted, let panel {
            panel.orderOut(nil)
            self.panel = nil
        }
    }
}

private struct OrbView: View {
    @Environment(RecorderController.self) private var recorder

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Color.purple.opacity(0.8), lineWidth: 3)
                    .frame(width: 64 + 20 * level(recorder.levels.call), height: 64 + 20 * level(recorder.levels.call))
                Circle()
                    .fill(BurrowColor.pensieve.gradient)
                    .frame(width: 52 + 8 * level(recorder.levels.mic), height: 52 + 8 * level(recorder.levels.mic))
                Text(clock(recorder.elapsed))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            .frame(width: 92, height: 92)
            .animation(.easeOut(duration: 0.15), value: recorder.levels.mic)
            HStack(spacing: 10) {
                Label("Jij", systemImage: "circle.fill").foregroundStyle(BurrowColor.pensieve)
                Label("Mac", systemImage: "circle.fill").foregroundStyle(.purple)
            }
            .labelStyle(OrbLegend())
            .font(.caption2)
            HStack(spacing: 8) {
                Button { recorder.mark() } label: { Image(systemName: "bookmark") }
                    .help("Markeer dit moment")
                Button { Task { await recorder.stop() } } label: { Image(systemName: "stop.fill") }
                    .tint(BurrowColor.danger)
                    .buttonStyle(.borderedProminent)
                    .help("Stop de opname")
            }
            .buttonBorderShape(.circle)
            .controlSize(.large)
        }
        .padding(14)
        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 22)))
        .padding(12)
    }

    private func level(_ decibels: Double) -> Double { max(0, min(1, (decibels + 50) / 50)) }
}

private struct OrbLegend: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title.foregroundStyle(.secondary)
        }
    }
}

/// Liquid glass from macOS 26, a material before.
struct Glass<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}
