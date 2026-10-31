// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
// Modified 2026-10-31 (ausfowler/bcd-games, Mobile Claw Deck): Home is MCD's carousel
// (MCDHomeView.swift); LB/RB switch GAMES and DOWNLOADS; Y opens the MCD menu, which reaches the
// Library, Settings and every other destination; Claw Deck's top pill, status pill and hint bar.

import SwiftUI

/// BCD's interface: the shell around Home, Library and Downloads (docs/BCD-UI-ARCHITECTURE.md).
/// Tabs across the top (LB/RB), the device's state on the right, the buttons' hints along
/// the bottom; on an upright iPhone the tabs move to the bottom. While a game runs
/// (`store.inGame`) the whole tree is gone, so it draws nothing and holds no animation.
struct BCDFrontEnd: View {
    @ObservedObject var store: BCDStore
    @StateObject private var focus: BCDFocus
    @State private var tab: BCDTab
    @State private var showSettings = false
    /// The section Settings opens at (the update chip's Updates); nil is its list.
    @State private var settingsSection: BCDSettingsSection?
    /// Y on the library tab: each press opens or closes its search.
    @State private var librarySearch = 0
    /// The menus over the shell (BCDMenu.swift): a game's, on a long press or X, and the library's sort.
    /// A plain reference: the screens only call it; the overlay (BCDMenuHost) is what observes it.
    @State private var cardMenu = BCDMenuModel()
    /// MCD: the carousel's selection and flip, kept while other screens are up.
    @StateObject private var carousel = MCDCarouselModel()
    /// MCD: the game whose page the flipped card's Settings opened.
    @State private var openedGame: BCDGame?
    @Environment(\.horizontalSizeClass) private var horizontal
    @Environment(\.verticalSizeClass) private var vertical

    init(store: BCDStore, tab: BCDTab = .home, focus: BCDFocus? = nil) {
        self.store = store
        _tab = State(initialValue: tab)
        _focus = StateObject(wrappedValue: focus ?? BCDFocus())
    }

    private var layout: BCDLayout { BCDLayout.of(horizontal: horizontal, vertical: vertical) }

    /// The hint bar under the screen: a controller was the last input and the screen has buttons.
    /// (Never on an upright iPhone, which has the tab bar there.) The screens read it as `\.bcdHintBar`.
    private var hintBarShown: Bool { layout != .phonePortrait && focus.controllerActive && !focus.hints.isEmpty }

    var body: some View {
        Group {
            if store.inGame {
                Color.black.ignoresSafeArea()
            } else {
                shell
            }
        }
        .onChange(of: store.inGame) { _, playing in
            focus.enabled = !playing
            // The game gets the memory the pictures held; they decode again afterwards.
            if playing { BCDArt.shared.purge() }
        }
    }

    private var shell: some View {
        VStack(spacing: 0) {
            // MCD: the bars sit over the backdrop, never under it (a wide art backdrop covered them in landscape).
            Group {
                if layout != .phonePortrait { topBar }
                else { portraitTitle }
            }
            .zIndex(2)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if layout == .phonePortrait { portraitTabs }
            else if hintBarShown { hintBar }
        }
        // MCD: Home's backdrop is the selected game's art behind the whole shell, bars included (Claw Deck).
        .background {
            if tab == .home {
                MCDBackdrop(game: homeGame)
            } else {
                BCDBackdrop()
            }
        }
        .coordinateSpace(name: BCDFocus.space)
        // The menu reads the focus and the layout from the environment: it sits inside them.
        .modifier(BCDMenuHost(model: cardMenu))
        .environment(\.bcdLayout, layout)
        .environment(\.bcdHintBar, hintBarShown)
        .environmentObject(focus)
        .environmentObject(store)
        .environment(\.bcdMenu, cardMenu)
        .foregroundStyle(BCDStyle.text)
        .preferredColorScheme(.dark)
        // Settings clears the buttons when it goes: the shell's come back once it has.
        .fullScreenCover(isPresented: $showSettings, onDismiss: { installButtons(); BCDPresentation.didClose() }) {
            BCDSettingsRoot(store: store, close: { showSettings = false; settingsSection = nil }, section: settingsSection)
                .environmentObject(focus)
        }
        .onAppear {
            cardMenu.store = store
            installButtons()
        }
        .onChange(of: tab) { _, _ in installButtons() }
        // MCD: A and B mean different things on a flipped card; the bar follows.
        .onChange(of: carousel.expanded) { _, _ in installButtons() }
        .onChange(of: carousel.settingsFocused) { _, _ in installButtons() }
        // Settings and the game page lead the D-pad themselves while they are up; Home takes it back after.
        .onChange(of: showSettings) { _, open in if !open { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { installButtons() } } }
        .onChange(of: openedGame) { _, game in if game == nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { installButtons() } } }
        // X shows while the ring is on a game's card.
        .onChange(of: focus.focused) { _, _ in installButtons() }
    }

    // MARK: Screens

    @ViewBuilder private var content: some View {
        switch tab {
        case .home:
            MCDHomeView(model: carousel, play: { playOrInstall($0) }, openPage: { openedGame = $0 })
                // Centred on the whole screen: in landscape the Duo keeps its status icons in a strip down one side
                // (the safe area), which pushed the carousel off centre. The bars still keep clear of the strip.
                .ignoresSafeArea(.container, edges: .horizontal)
                .bcdGamePage($openedGame, from: "Home")
                .onAppear { cardMenu.openPage = { openedGame = $0 } }
        case .library: BCDLibraryView(searchRequest: librarySearch)
        case .downloads: BCDDownloadsView()
        }
    }

    private func installButtons() {
        // A page or menu over the shell has its own buttons; Settings sets its own too.
        guard !focus.layerOpen, !showSettings else { return }
        var list: [(BCDHint, () -> Void)] = [
            (BCDHint(button: .leftShoulder, title: "Previous"), { cycle(-1) }),
            (BCDHint(button: .rightShoulder, title: "Next"), { cycle(1) }),
        ]
        if tab == .home {
            // MCD: Claw Deck's Home. The carousel leads Left/Right; A flips the card, then plays or opens Settings.
            let games = MCDCarouselModel.order(store.games)
            let current: BCDGame? = games.isEmpty ? nil : games[carousel.index(in: games)]
            if carousel.expanded {
                list.append((BCDHint(button: .a, title: "Confirm"), {
                    guard let game = current else { return }
                    if carousel.settingsFocused { openedGame = game } else { playOrInstall(game) }
                }))
                list.append((BCDHint(button: .b, title: "Back"), { carousel.setExpanded(false) }))
            } else {
                list.append((BCDHint(button: .a, title: "Select"), { if current != nil { carousel.setExpanded(true) } }))
            }
            if let game = current { list.append((BCDHint(button: .x, title: "Options"), { cardMenu.showCard(game.id) })) }
            focus.steer = { direction in
                guard tab == .home, !focus.layerOpen, !showSettings, openedGame == nil else { return false }
                switch direction {
                case .left: carousel.step(-1, in: MCDCarouselModel.order(store.games))
                case .right: carousel.step(1, in: MCDCarouselModel.order(store.games))
                case .up, .down: break   // Claw Deck: Up and Down do nothing on the carousel
                }
                return true
            }
        } else {
            focus.steer = nil
            list.append((BCDHint(button: .a, title: tab == .downloads ? "Pause or resume" : "Open"), {}))
            // A game's menu: X while the ring is on its card (the Library's grid).
            if tab != .downloads, let game = BCDMenuModel.gameID(focused: focus.focused, store: store) {
                list.append((BCDHint(button: .x, title: "Options"), { cardMenu.showCard(game) }))
            }
            // Claw Deck: B from the Library (and Downloads) goes Home.
            list.append((BCDHint(button: .b, title: "Home"), { withAnimation(MCDMotion.pop) { tab = .home } }))
        }
        list.append((BCDHint(button: .y, title: "Menu"), { showMCDMenu() }))
        list.append((BCDHint(button: .menu, title: "Settings"), { openSettings() }))
        focus.setHandlers(list)
    }

    /// MCD's Y menu (Claw Deck's): every destination the shell had, in one list.
    private func showMCDMenu() {
        guard !cardMenu.isOpen else { cardMenu.dismiss(); return }
        var items: [BCDMenuItem] = []
        if tab != .home {
            items.append(BCDMenuItem(id: "mcd.home", title: "Home", symbol: "house.fill") { withAnimation(MCDMotion.pop) { tab = .home } })
        }
        items.append(BCDMenuItem(id: "mcd.library", title: "Library", symbol: "square.grid.2x2.fill") { withAnimation(MCDMotion.pop) { tab = .library } })
        if tab == .library {
            items.append(BCDMenuItem(id: "mcd.search", title: "Search the library", symbol: "magnifyingglass") { librarySearch += 1 })
        }
        items.append(BCDMenuItem(id: "mcd.downloads", title: "Downloads", symbol: "arrow.down.circle.fill",
                                 detail: store.downloads.isEmpty ? nil : "\(store.downloads.count) in progress") { withAnimation(MCDMotion.pop) { tab = .downloads } })
        items.append(BCDMenuItem(id: "mcd.settings", title: "Settings", symbol: "gearshape.fill") { openSettings() })
        items.append(BCDMenuItem(id: "mcd.add", title: "Add a game", symbol: "plus.circle.fill") { store.actions?.addGameFromFiles() })
        items.append(BCDMenuItem(id: "mcd.launchers", title: "Launchers", symbol: "app.badge.fill",
                                 detail: "Battle.net, EA app and more, in the Library") { withAnimation(MCDMotion.pop) { tab = .library } })
        items.append(BCDMenuItem(id: "mcd.accounts", title: "Accounts", symbol: "person.crop.circle.fill") { openSettings(.accounts) })
        items.append(BCDMenuItem(id: "mcd.controls", title: "Controls", symbol: "gamecontroller.fill") { openSettings(.controls) })
        items.append(BCDMenuItem(id: "mcd.storage", title: "Storage", symbol: "internaldrive.fill") { openSettings(.storage) })
        items.append(BCDMenuItem(id: "mcd.refresh", title: "Refresh the library", symbol: "arrow.clockwise") { store.actions?.refreshLibrary() })
        cardMenu.show(BCDMenuContent(title: "Mobile Claw Deck", items: items))
    }

    private func openSettings() {
        showSettings = true
    }

    /// Settings at one section (the MCD menu's Accounts, Controls, Storage).
    private func openSettings(_ section: BCDSettingsSection) {
        settingsSection = section
        showSettings = true
    }

    private func cycle(_ step: Int) {
        // MCD: LB/RB switch GAMES and DOWNLOADS (Claw Deck's GAMES/APPS pill); the Library is in the Y menu.
        let pair: [BCDTab] = [.home, .downloads]
        let index = pair.firstIndex(of: tab).map { ($0 + step + pair.count) % pair.count } ?? 0
        withAnimation(MCDMotion.pop) { tab = pair[index] }
    }

    // MARK: Bars

    private var topBar: some View {
        HStack(spacing: 10) {
            if focus.controllerActive { shoulder("LB") }
            MCDTabPill(tab: $tab, downloads: store.downloads.count)
            if focus.controllerActive { shoulder("RB") }
            if tab == .library {
                Text("LIBRARY").font(BCDStyle.caps(15)).tracking(3).foregroundStyle(BCDStyle.lavender)
                    .padding(.leading, 6)
            }
            Spacer(minLength: 12)
            statusChips
            menuButton
            settingsButton
        }
        .padding(.horizontal, layout.gutter).padding(.top, layout == .pad ? 12 : 8).padding(.bottom, 6)
    }

    /// The MCD menu for touch (Y on a controller).
    private var menuButton: some View {
        Button { showMCDMenu() } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 38, height: 38)
                .bcdGlass(cornerRadius: 19)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Menu")
    }

    /// The flipped card's main button: Play when the game is installed, else Install (to the device, BCD's default place).
    private func playOrInstall(_ game: BCDGame) {
        if game.state.isInstalled { store.actions?.play(game) } else { store.actions?.install(game, place: .device) }
    }

    /// The carousel's selected game (Home's backdrop).
    private var homeGame: BCDGame? {
        let games = MCDCarouselModel.order(store.games)
        return games.isEmpty ? nil : games[carousel.index(in: games)]
    }

    private var portraitTitle: some View {
        HStack {
            Text(tab.title).font(BCDStyle.title(30))
            Spacer()
            statusChips
            menuButton
            settingsButton
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 6)
    }

    private var portraitTabs: some View {
        HStack {
            ForEach(BCDTab.allCases) { item in
                Button { tab = item } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.symbol).font(.system(size: 20, weight: .semibold))
                        Text(item.title).font(BCDStyle.label(11))
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(item == tab ? AnyShapeStyle(BCDStyle.glow) : AnyShapeStyle(BCDStyle.textSoft))
                    .overlay(alignment: .topTrailing) {
                        if item == .downloads && !store.downloads.isEmpty { badge.offset(x: -22, y: -2) }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 6)
        .background(BCDStyle.ground.opacity(0.92).ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(BCDStyle.stroke).frame(height: 1) }
    }

    private func tabButton(_ item: BCDTab) -> some View {
        let selected = item == tab
        return Button { withAnimation(.easeOut(duration: 0.18)) { tab = item } } label: {
            HStack(spacing: 7) {
                Text(item.title).font(BCDStyle.heading(layout == .pad ? 18 : 16))
                if item == .downloads && !store.downloads.isEmpty { badge }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .foregroundStyle(selected ? BCDStyle.ground : BCDStyle.textSoft)
            .background { if selected { Capsule().fill(BCDStyle.text) } }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var badge: some View {
        Text("\(store.downloads.count)")
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .frame(minWidth: 18, minHeight: 18)
            .background(BCDStyle.glow, in: Capsule())
    }

    /// Claw Deck's shoulder key: a small outlined box.
    private func shoulder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(BCDStyle.lavender)
            .frame(width: 34, height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
            .accessibilityHidden(true)
    }

    /// Claw Deck's status pill: the controller and its battery, BCD's JIT and update chips, the clock.
    @ViewBuilder private var statusChips: some View {
        let system = store.system
        HStack(spacing: 12) {
            BCDUpdateChip { settingsSection = .updates; showSettings = true }
            if layout != .phonePortrait || system.jit != .on {
                BCDStatusChip(text: system.jit == .on ? "JIT on" : system.jit == .waiting ? "JIT…" : "JIT off",
                              color: system.jit == .on ? BCDStyle.mint : Color(red: 1, green: 0.76, blue: 0.29))
            }
            if layout == .pad, let limit = system.memoryLimitBytes {
                BCDStatusChip(text: "Memory \(BCDFormat.bytes(limit))",
                              color: system.increasedMemoryLimit ? BCDStyle.mint : Color(red: 1, green: 0.76, blue: 0.29))
            }
            if layout != .phonePortrait {
                HStack(spacing: 12) {
                    if let name = system.controllerName {
                        Image(systemName: "gamecontroller.fill").font(.system(size: 17, weight: .semibold))
                            .accessibilityLabel(name)
                        if let battery = system.controllerBattery {
                            Text("\(battery)%").font(BCDStyle.label(15)).foregroundStyle(BCDStyle.mint)
                        }
                        Rectangle().fill(Color.white.opacity(0.18)).frame(width: 1, height: 18)
                    }
                    TimelineView(.everyMinute) { context in
                        // Never `Text(date, format:)`: ICU date formatting killed BCD at launch (BCDFormat, udat_open).
                        Text(MCDFormat.clock(context.date)).font(BCDStyle.label(16)).monospacedDigit()
                    }
                }
                .padding(.horizontal, 16).frame(height: 38)
                .bcdGlass(cornerRadius: 19)
            }
        }
    }

    private var settingsButton: some View {
        Button { openSettings() } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 38, height: 38)
                .bcdGlass(cornerRadius: 19)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
    }

    /// Claw Deck's footer: the buttons' hints in one centred glass capsule.
    private var hintBar: some View {
        HStack(spacing: 24) {
            ForEach(focus.hints.filter { $0.button != .leftShoulder && $0.button != .rightShoulder && $0.button != .menu }) { BCDHintView(hint: $0) }
        }
        .padding(.horizontal, 22).frame(height: 40)
        .bcdGlass(cornerRadius: 20)
        // Under a menu or page the overlay draws its own hints; the bar keeps its room.
        .opacity(focus.layerOpen ? 0 : 1)
        .frame(maxWidth: .infinity).frame(height: 48)
        .padding(.bottom, 4)
    }
}

/// Claw Deck's GAMES / APPS pill, here GAMES / DOWNLOADS: spaced capitals, the chosen one on a
/// lighter capsule that slides across (the pop spring).
struct MCDTabPill: View {
    @Binding var tab: BCDTab
    let downloads: Int
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 4) {
            item(.home, "GAMES")
            item(.downloads, downloads > 0 ? "DOWNLOADS · \(downloads)" : "DOWNLOADS")
        }
        .padding(4)
        .bcdGlass(cornerRadius: 26)
    }

    private func item(_ value: BCDTab, _ title: String) -> some View {
        let on = tab == value
        return Button { withAnimation(MCDMotion.pop) { tab = value } } label: {
            Text(title)
                .font(BCDStyle.caps(18)).tracking(3)
                .foregroundStyle(on ? Color.white : Color.white.opacity(0.42))
                .padding(.horizontal, 18).frame(height: 40)
                .background {
                    if on {
                        Capsule().fill(Color.white.opacity(0.16))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                            .matchedGeometryEffect(id: "mcd.tab", in: pill)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

enum BCDTab: String, CaseIterable, Identifiable {
    case home, library, downloads
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Games"
        case .library: return "Library"
        case .downloads: return "Downloads"
        }
    }
    var symbol: String {
        switch self {
        case .home: return "gamecontroller.fill"
        case .library: return "square.grid.2x2.fill"
        case .downloads: return "arrow.down.circle.fill"
        }
    }
}
