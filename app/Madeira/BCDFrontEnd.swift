// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
// Modified 2026-10-31 (ausfowler/bcd-games, Mobile Claw Deck): Home is MCD's carousel
// (MCDHomeView.swift); LB/RB switch GAMES and DOWNLOADS; Y opens the MCD menu, which reaches the
// Library, Settings and every other destination; Claw Deck's top pill, status pill and hint bar.
// Modified 2026-11-02: the flipped card's Cloud button (MCD Cloud, layout A) and what A does on it.
// Modified 2026-11-02 (phase 3): Cloud plays the game: MCD's cloud screen (MCDCloudPlay.swift) over the shell.
// Modified 2026-11-02 (phase 4): the iPhone Duo's top bar: JIT in the menu, the title on one line, the camera kept clear.

import SwiftUI
import UIKit

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
            // MCD: even room at both sides of the screen (the Duo's status strip sits down one side).
            .modifier(MCDEvenSides())
            .zIndex(2)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if layout == .phonePortrait { portraitTabs }
            else if hintBarShown { hintBar }
        }
        // MCD: Home's backdrop is the selected game's art behind the whole shell, bars included (Claw Deck).
        // MCD: a newer BCD is announced in the bottom-left corner, not in the top bar (it widened the bar past the screen).
        // MCD: the window's side insets for the even sides (MCDEvenSides), measured where no padding can change them.
        .background { MCDSafeAreaProbe().ignoresSafeArea().allowsHitTesting(false) }
        .overlay(alignment: .bottomLeading) {
            MCDUpdateNotice { settingsSection = .updates; showSettings = true }
                .padding(.leading, layout.gutter).padding(.bottom, hintBarShown ? 58 : 14)
        }
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
        // MCD Cloud: the session's screen and the stream, over everything else in the shell (and its menus).
        .modifier(MCDCloudHost(model: MCDCloudPlay.shared))
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
        .onChange(of: carousel.cardButton) { _, _ in installButtons() }
        // MCD Cloud: a card can gain or lose its Cloud button when the catalog or the account changes.
        .onReceive(MCDCloudCards.shared.$revision) { _ in installButtons() }
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
            MCDHomeView(model: carousel, play: { playOrInstall($0) }, cloud: { cloudPressed($0) }, openPage: { openedGame = $0 })
                // Centred on the whole screen: in landscape the Duo keeps its status icons in a strip down one side
                // (the safe area), which pushed the carousel off centre. The bars still keep clear of the strip.
                .ignoresSafeArea(.container, edges: .horizontal)
                .bcdGamePage($openedGame, from: "Home")
                .onAppear { cardMenu.openPage = { openedGame = $0 } }
        // MCD: the Library and Downloads are centred on the screen, with equal room at both sides (the hint bar's centre).
        case .library: BCDLibraryView(searchRequest: librarySearch).modifier(MCDEvenSides())
        case .downloads: BCDDownloadsView().modifier(MCDEvenSides())
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
                // The hint names what A does on the button the ring is on.
                let title: String
                if let game = current {
                    switch carousel.button(for: game) {
                    case .main: title = game.state.isInstalled ? "Play" : "Install"
                    case .cloud: title = MCDCloudCards.shared.state(game).map(Self.cloudHint) ?? "Play"
                    case .settings: title = "Settings"
                    }
                } else {
                    title = "Confirm"
                }
                list.append((BCDHint(button: .a, title: title), {
                    guard let game = current else { return }
                    switch carousel.button(for: game) {
                    case .main: playOrInstall(game)
                    case .cloud: cloudPressed(game)
                    case .settings: openedGame = game
                    }
                }))
                list.append((BCDHint(button: .b, title: "Back"), { carousel.setExpanded(false) }))
            } else {
                list.append((BCDHint(button: .a, title: "Select"), { if let current { carousel.setExpanded(true, game: current) } }))
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
        } else if tab == .library {
            // MCD: Claw Deck's grid -- the D-pad steps card by card through the whole library, LT/RT turn a page,
            // and the page follows the ring (BCDLibraryView, MCDLibraryNav).
            focus.steer = { direction in
                guard tab == .library, !focus.layerOpen, !showSettings else { return false }
                return MCDLibraryNav.shared.move(direction, focus: focus)
            }
            list.append((BCDHint(button: .a, title: "Open"), {}))
            list.append((BCDHint(button: .leftTrigger, title: "Page"), { MCDLibraryNav.shared.turnPage(-1, focus: focus) }))
            list.append((BCDHint(button: .rightTrigger, title: "Page"), { MCDLibraryNav.shared.turnPage(1, focus: focus) }))
            if let game = BCDMenuModel.gameID(focused: focus.focused, store: store) {
                list.append((BCDHint(button: .x, title: "Options"), { cardMenu.showCard(game) }))
            }
            list.append((BCDHint(button: .b, title: "Home"), { withAnimation(MCDMotion.pop) { tab = .home } }))
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
        // The status the top bar shows (and the compact bar leaves out): JIT, and the memory limit when measured.
        let system = store.system
        var status = system.jit == .on ? "JIT on" : system.jit == .waiting ? "JIT starting" : "JIT off"
        if let limit = system.memoryLimitBytes { status += " · Memory \(BCDFormat.bytes(limit))" }
        items.append(BCDMenuItem(id: "mcd.status", title: "Status", symbol: "bolt.horizontal.circle", detail: status) { openSettings(.jit) })
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

    /// MCD: the full bar when it fits, else the compact one (the Duo's closed screen on its side): a smaller tab pill, the
    /// clock and the menu, with the gear and the JIT/memory status inside the menu. Whichever is shown fits the screen, so
    /// the bar can never lay the whole app out wider than the display again.
    private var topBar: some View {
        Group {
            if MCDDuo.isThisPhone {
                // MCD (phase 4): on the iPhone Duo always the compact bar, JIT's state in the menu (Status), as its open screen
                // already had it. Closed and on its side one way, the full bar used to fit, and ran under the camera.
                topBarRow(compact: true)
            } else {
                ViewThatFits(in: .horizontal) {
                    topBarRow(compact: false)
                    topBarRow(compact: true)
                }
            }
        }
        .modifier(MCDCameraClearance())
        .padding(.horizontal, layout.gutter).padding(.top, layout == .pad ? 12 : 8).padding(.bottom, 6)
    }

    private func topBarRow(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 10) {
            if focus.controllerActive { shoulder("LB") }
            MCDTabPill(tab: $tab, downloads: store.downloads.count, compact: compact).fixedSize()
            if focus.controllerActive { shoulder("RB") }
            if tab == .library && !compact {
                // The label gives way when the bar is short of room, never the tabs or the buttons.
                ViewThatFits(in: .horizontal) {
                    Text("LIBRARY").font(BCDStyle.caps(15)).tracking(3).foregroundStyle(BCDStyle.lavender).fixedSize()
                        .padding(.leading, 6)
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            Spacer(minLength: 12)
            if compact { clockPill } else { statusChips }
            menuButton
            if !compact { settingsButton }
        }
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

    /// MCD Cloud: the card's Cloud button. Ready: streaming is phase 3 of the build plan, so for now it
    /// says so in the menu card instead of doing nothing. A store to link: NVIDIA's page opens in Safari.
    private func cloudPressed(_ game: BCDGame) {
        switch MCDCloudCards.shared.state(game) {
        case .ready?:
            MCDCloudPlay.shared.play(game)
        case .link(let store, _)?:
            MCDCloudCards.shared.link(store)
        case nil:
            break
        }
    }

    private static func cloudHint(_ state: MCDCloudCardState) -> String {
        switch state {
        case .ready: return "Play with Cloud"
        case .link(_, let label): return "Link \(label)"
        }
    }

    /// The carousel's selected game (Home's backdrop).
    private var homeGame: BCDGame? {
        let games = MCDCarouselModel.order(store.games)
        return games.isEmpty ? nil : games[carousel.index(in: games)]
    }

    private var portraitTitle: some View {
        HStack {
            // MCD (phase 4): one line, never "Game / s"; the Duo's JIT state is in the menu (Status), not beside it.
            Text(tab.title).font(BCDStyle.title(30)).lineLimit(1).minimumScaleFactor(0.6).layoutPriority(1)
            Spacer()
            if !MCDDuo.isThisPhone { statusChips }
            menuButton
            settingsButton
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 6)
    }

    /// The tab bar of an upright phone: its ground runs edge to edge (it stopped at the status strip on the Duo's closed
    /// screen), and the three tabs sit together in the middle with the same room on both sides.
    private var portraitTabs: some View {
        HStack(spacing: 0) {
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
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
        .modifier(MCDEvenSides())
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                BCDStyle.ground.opacity(0.92)
                Rectangle().fill(BCDStyle.stroke).frame(height: 1)
            }
            .ignoresSafeArea(.container, edges: [.bottom, .horizontal])
        }
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

    /// Claw Deck's status pill: BCD's update, JIT and memory chips, and the clock. The controller and its battery
    /// sit in the hint bar (it is only there while a controller is in use), so plugging one in no longer squeezes
    /// this row. When the row is still short of room, the chips give way first, never the tabs or the clock.
    @ViewBuilder private var statusChips: some View {
        HStack(spacing: 12) {
            // (BCD's "Update available" chip is the corner notice now: MCDUpdateNotice, over the shell.)
            ViewThatFits(in: .horizontal) {
                systemChips(.full)
                systemChips(.short)
                systemChips(.dot)
            }
            .layoutPriority(1)
            if layout != .phonePortrait { clockPill }
        }
    }

    /// The clock in its glass pill.
    private var clockPill: some View {
        TimelineView(.everyMinute) { context in
            // Never `Text(date, format:)`: ICU date formatting killed BCD at launch (BCDFormat, udat_open).
            Text(MCDFormat.clock(context.date)).font(BCDStyle.label(16)).monospacedDigit()
                .lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 16).frame(height: 38)
        .bcdGlass(cornerRadius: 19)
        .fixedSize()
    }

    private enum ChipDetail { case full, short, dot }

    /// JIT and (on a large screen) memory, in as many words as the row has room for.
    private func systemChips(_ detail: ChipDetail) -> some View {
        let system = store.system
        let amber = Color(red: 1, green: 0.76, blue: 0.29)
        return HStack(spacing: 8) {
            if layout != .phonePortrait || system.jit != .on {
                let jit = system.jit == .on ? "JIT on" : system.jit == .waiting ? "JIT…" : "JIT off"
                MCDStatusChip(text: detail == .dot ? nil : (detail == .short ? "JIT" : jit), color: system.jit == .on ? BCDStyle.mint : amber)
                    .accessibilityLabel(jit)
            }
            if layout == .pad, let limit = system.memoryLimitBytes {
                let memory = "Memory \(BCDFormat.bytes(limit))"
                MCDStatusChip(text: detail == .dot ? nil : (detail == .short ? BCDFormat.bytes(limit) : memory),
                              color: system.increasedMemoryLimit ? BCDStyle.mint : amber)
                    .accessibilityLabel(memory)
            }
        }
        .fixedSize()
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

    /// Claw Deck's footer: the controller and its battery, then the buttons' hints, in one glass capsule centred on
    /// the whole screen (the Duo's status strip down one side no longer pulls it off centre).
    private var hintBar: some View {
        HStack(spacing: 24) {
            if let name = store.system.controllerName {
                HStack(spacing: 8) {
                    Image(systemName: "gamecontroller.fill").font(.system(size: 16, weight: .semibold))
                    if let battery = store.system.controllerBattery {
                        Text("\(battery)%").font(BCDStyle.label(15)).foregroundStyle(BCDStyle.mint).monospacedDigit()
                    }
                }
                .fixedSize()
                .accessibilityElement(children: .combine)
                .accessibilityLabel(name)
                Rectangle().fill(Color.white.opacity(0.18)).frame(width: 1, height: 18)
            }
            // RT is drawn with LT ("LT RT · Page"), as on Claw Deck.
            ForEach(focus.hints.filter { ![.leftShoulder, .rightShoulder, .menu, .rightTrigger].contains($0.button) }) { BCDHintView(hint: $0) }
        }
        .padding(.horizontal, 22).frame(height: 40)
        .bcdGlass(cornerRadius: 20)
        // Under a menu or page the overlay draws its own hints; the bar keeps its room.
        .opacity(focus.layerOpen ? 0 : 1)
        .frame(maxWidth: .infinity).frame(height: 48)
        .padding(.bottom, 4)
        .ignoresSafeArea(.container, edges: .horizontal)
    }
}

/// A status chip that can shrink to its dot (BCDStatusChip's look; `text` nil draws the dot alone).
struct MCDStatusChip: View {
    let text: String?
    let color: Color
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            if let text { Text(text).font(BCDStyle.label(12)).lineLimit(1).fixedSize() }
        }
        .padding(.horizontal, text == nil ? 8 : 10).padding(.vertical, 6)
        .background(BCDStyle.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(BCDStyle.stroke, lineWidth: 1))
    }
}

/// Claw Deck's GAMES / APPS pill, here GAMES / DOWNLOADS: spaced capitals, the chosen one on a
/// lighter capsule that slides across (the pop spring).
struct MCDTabPill: View {
    @Binding var tab: BCDTab
    let downloads: Int
    /// The narrow screen's pill: smaller capitals, and the download count as a small badge.
    var compact = false
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 4) {
            item(.home, "GAMES")
            item(.downloads, downloads > 0 && !compact ? "DOWNLOADS · \(downloads)" : "DOWNLOADS")
        }
        .padding(compact ? 3 : 4)
        .bcdGlass(cornerRadius: 26)
    }

    private func item(_ value: BCDTab, _ title: String) -> some View {
        let on = tab == value
        return Button { withAnimation(MCDMotion.pop) { tab = value } } label: {
            Text(title)
                .font(BCDStyle.caps(compact ? 13 : 18)).tracking(compact ? 1.8 : 3).lineLimit(1).fixedSize()
                .foregroundStyle(on ? Color.white : Color.white.opacity(0.42))
                .padding(.horizontal, compact ? 12 : 18).frame(height: compact ? 32 : 40)
                .overlay(alignment: .topTrailing) {
                    if compact && value == .downloads && downloads > 0 {
                        Text("\(downloads)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(BCDStyle.accent, in: Capsule())
                            .offset(x: 4, y: -3)
                    }
                }
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

/// MCD: BCD's update notice as a corner card (it was a chip in the top bar). Shown while BCD's own checker says a newer official
/// BCD is out; in this fork the way to it is GitHub's Sync fork, so the card says so. Tap: Settings › Updates. ✕ hides it until a
/// newer version than the one dismissed comes out.
struct MCDUpdateNotice: View {
    @ObservedObject private var checker = BCDUpdateChecker.shared
    @AppStorage("mcd.update.dismissed") private var dismissed = ""
    let open: () -> Void

    var body: some View {
        if checker.showsChip, let latest = checker.latest, latest.version != dismissed {
            HStack(spacing: 12) {
                Button(action: open) {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle.fill").font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(BCDStyle.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("BCD \(latest.version) is out").font(BCDStyle.label(14))
                            Text("Sync your fork to get it").font(BCDStyle.body(12)).foregroundStyle(BCDStyle.textSoft)
                        }
                    }
                }
                .buttonStyle(.plain)
                Button { withAnimation(MCDMotion.pop) { dismissed = latest.version } } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(BCDStyle.textSoft)
                        .frame(width: 26, height: 26).background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide")
            }
            .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 10)
            .bcdGlass(cornerRadius: 16)
            .fixedSize()
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// MCD (phase 4): this phone is the iPhone Duo (by its model, whatever the experimental foldable switch says): the
/// shell's top bar is the compact one, with JIT's state in the menu, and keeps clear of the closed screen's camera.
enum MCDDuo {
    static let isThisPhone = BCDFoldableDevice.isThisDevice
}

/// The top bar's room for the iPhone Duo's camera (MCDSafeSides.cameraRoom); none anywhere else.
struct MCDCameraClearance: ViewModifier {
    @ObservedObject private var sides = MCDSafeSides.shared
    func body(content: Content) -> some View {
        content.padding(.leading, sides.camera)
    }
}

/// MCD: content centred on the whole screen with even sides. In landscape the Duo keeps its status icons in a strip down one
/// side (the safe area), and content laid out beside it sat off centre. This takes the content out to both screen edges and
/// pads each side by the larger of the two insets, so it clears the strip and has the same room on the left as on the right.
///
/// The insets come from MCDSafeSides, measured by one full-screen probe that nothing here can resize. (An earlier version
/// measured them from the padded view itself and set the padding from that during layout; on rotation the two fed each other
/// and the app froze half way through the turn.)
struct MCDEvenSides: ViewModifier {
    @ObservedObject private var sides = MCDSafeSides.shared

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, sides.even)
            .ignoresSafeArea(.container, edges: .horizontal)
    }
}

/// The window's side insets, as the larger of left and right. Set from outside any layout pass (the next turn of the main
/// queue), and only when it really changes.
@MainActor final class MCDSafeSides: ObservableObject {
    static let shared = MCDSafeSides()
    @Published private(set) var even: CGFloat = 0
    /// MCD (phase 4): room the top bar leaves on its leading side for the iPhone Duo's camera (MCDCameraClearance).
    @Published private(set) var camera: CGFloat = 0
    private var pending: CGFloat?

    /// The iPhone Duo closed and on its side with the camera at the top left reports no inset for the camera, so the
    /// bar ran under it (Austin's screenshot, 2026-11-02: the camera reaches 9.75% of the width in). On the closed
    /// screen on its side, either way round (which way puts the camera there is not assumed: the other way the pill
    /// only sits a little further in), this much of the width is kept clear at the bar's leading side.
    static func cameraRoom(foldable: Bool, size: CGSize) -> CGFloat {
        guard foldable, size.width > size.height,
              size.width < 940 else { return 0 }   // the open screen is 951 pt wide (the foldable log); narrower is the closed one
        return (size.width * 0.10).rounded()
    }

    func report(view: UIView) {
        report(view.safeAreaInsets)
        let value = Self.cameraRoom(foldable: MCDDuo.isThisPhone, size: view.bounds.size)
        guard value != camera else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, value != self.camera else { return }
            self.camera = value
        }
    }

    func report(_ insets: UIEdgeInsets) {
        let value = max(insets.left, insets.right)
        guard value.isFinite, value >= 0, value < 400 else { return }
        guard abs(value - (pending ?? even)) > 0.5 else { return }
        pending = value
        DispatchQueue.main.async { [weak self] in
            guard let self, let value = self.pending else { return }
            self.pending = nil
            if abs(value - self.even) > 0.5 { self.even = value }
        }
    }
}

/// An invisible full-window view that reports the window's safe-area insets (UIKit tells it when they change). It is the
/// shell's background, ignoring the safe area, so its size never depends on the padding it causes.
struct MCDSafeAreaProbe: UIViewRepresentable {
    final class Probe: UIView {
        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            MCDSafeSides.shared.report(view: self)
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { MCDSafeSides.shared.report(view: self) }
        }
        // MCD (phase 4): a turn changes the size (and the camera's side) even where the insets stay the same.
        override func layoutSubviews() {
            super.layoutSubviews()
            if window != nil { MCDSafeSides.shared.report(view: self) }
        }
    }
    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }
    func updateUIView(_ uiView: Probe, context: Context) {}
}
