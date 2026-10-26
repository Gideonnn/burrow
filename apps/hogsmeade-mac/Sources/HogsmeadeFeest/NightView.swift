import BurrowUI
import HogsmeadeCore
import HogsmeadeUI
import SwiftUI

/// The playful face (docs/design/hogsmeade-style.html): one screen at a
/// time. The wall greets you with the next outing and the posters as a hand
/// of cards; on the day itself the outing takes the whole screen over; an
/// outing opens as a page in a scrapbook. A floating island navigates.
struct NightView: View {
    @Environment(OutingsModel.self) private var model
    @State private var adding = false
    @State private var party: UUID?
    @FocusState private var searchFocused: Bool

    private enum Screen: Equatable { case tonight, wall, past, outing(String) }

    private var screen: Screen {
        if let open = model.open { return .outing(open.id) }
        if model.page == .past { return .past }
        if let today = model.today, !model.tonightHidden, model.query.isEmpty, model.filter == nil { return .tonight }
        return .wall
    }

    var body: some View {
        @Bindable var model = model
        ZStack {
            Group {
                switch screen {
                case .tonight:
                    if let today = model.today { TonightScreen(outing: today, showWall: { model.tonightHidden = true }) }
                case .wall:
                    WallScreen(searchFocused: $searchFocused, tonightHidden: model.today != nil && model.tonightHidden, showTonight: { model.tonightHidden = false })
                case .past:
                    PastScreen(searchFocused: $searchFocused)
                case .outing(let id):
                    if let outing = model.outings.first(where: { $0.id == id }) {
                        Scrapbook(outing: outing, party: $party)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .animation(.snappy(duration: 0.3), value: screen)
            if model.open == nil {
                VStack {
                    Spacer()
                    Island(adding: $adding)
                        .padding(.bottom, 18)
                }
            }
            if let toast = model.toast {
                VStack {
                    Spacer()
                    ToastPill(text: toast.message).padding(.bottom, 84)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            ConfettiBurst(trigger: party ?? (model.lastChange?.kind == .allDone ? model.lastChange?.id : nil))
        }
        .animation(.snappy, value: model.toast)
        .background(Palette.night.ignoresSafeArea())
        .sheet(isPresented: $adding) { NewOutingPanel() }
        .onChange(of: model.newRequest) { adding = true }
        .onChange(of: model.searchFocusRequest) { model.tonightHidden = true; model.close(); searchFocused = true }
        .onChange(of: model.query) { if !model.query.isEmpty { model.close() } }
        .onKeyPress(.escape) {
            if searchFocused { searchFocused = false; model.query = ""; return .handled }
            if model.open != nil || !model.query.isEmpty { model.escape(); return .handled }
            if model.tonightHidden { model.tonightHidden = false; return .handled }
            return .ignored
        }
        .onKeyPress(.return) {
            guard model.open == nil, model.page == .upcoming, let first = model.shown.first else { return .ignored }
            model.open(first.id)
            return .handled
        }
    }
}

/// The floating navigation at the bottom.
struct Island: View {
    @Environment(OutingsModel.self) private var model
    @Binding var adding: Bool

    var body: some View {
        HStack(spacing: 4) {
            tab("Binnenkort", "sparkles", selected: model.page == .upcoming) { model.page = .upcoming; model.filter = nil }
            tab("Geweest", "clock", selected: model.page == .past) { model.page = .past; model.filter = nil }
            Button { adding = true } label: {
                Image(systemName: "plus").font(.round(18, .bold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(Circle().fill(.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .help("Nieuw uitje (⌘N)")
            .disabled(!model.canOrganize)
        }
        .padding(6)
        .background(Capsule().fill(Palette.night.opacity(0.6)).background(.ultraThinMaterial, in: Capsule()))
        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
    }

    private func tab(_ title: String, _ icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.round(14, .bold))
                .foregroundStyle(selected ? Palette.onLemon : Palette.mutedOnNight)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(Capsule().fill(selected ? Palette.lemon : .clear))
        }
        .buttonStyle(.plain)
    }
}

struct ToastPill: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark").font(.round(11, .heavy)).foregroundStyle(Palette.onMint)
                .frame(width: 18, height: 18).background(Circle().fill(Palette.mint))
            Text(text).font(.round(13, .bold)).foregroundStyle(.white)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Capsule().fill(Palette.night.opacity(0.92)))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
    }
}

/// The search pill and the household's faces, top right.
struct TopBar: View {
    @Environment(OutingsModel.self) private var model
    var searchFocused: FocusState<Bool>.Binding
    var dark = true

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 10) {
            UpdateBanner(appName: "Hogsmeade Feest") { (NSApp.delegate as? AppDelegate)?.restart() }
                .frame(maxWidth: 260)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.round(13, .bold))
                TextField("Zoek een uitje", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.round(13, .semibold))
                    .focused(searchFocused)
                    .frame(width: searchFocused.wrappedValue || !model.query.isEmpty ? 170 : 110)
            }
            .foregroundStyle(dark ? Color(hex: 0xE7E1F5) : Palette.mutedOnCream)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(Capsule().fill(dark ? .white.opacity(0.1) : .white))
            .animation(.snappy, value: searchFocused.wrappedValue)
            HStack(spacing: -8) {
                ForEach(model.people) { person in
                    Avatar(person.name, size: 34).overlay(Circle().strokeBorder(dark ? Palette.night : Palette.cream, lineWidth: 2))
                }
            }
        }
    }
}
