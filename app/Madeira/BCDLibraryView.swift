// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
// Modified 2026-10-31 (ausfowler/bcd-games, Mobile Claw Deck): a controller-first grid -- the D-pad steps
// card by card through the whole library (MCDLibraryNav), the page follows the ring, LT/RT turn a page.

import SwiftUI

/// Library: every game the stores say you own and every game you added, installed or not,
/// filtered by store, sorted as the classic library sorted (last played, name, recently added, folder
/// size) and found by name. The filter and the order stay as they were set, across games and launches. Signed out of Steam, a card offers the
/// sign-in; with no game added by hand, a line says how games get into drive_c.
struct BCDLibraryView: View {
    @EnvironmentObject private var store: BCDStore
    @Environment(\.bcdLayout) private var layout
    /// Y in the shell (BCDFrontEnd): each press opens the search, or closes an open one.
    var searchRequest = 0
    @AppStorage("bcd.library.filter") private var filterKey = BCDLibraryFilter.all.rawValue
    /// The order: BCDLibrarySort's key. Before the sort menu there was only a switch between recent
    /// play and name, kept in `sortByName`; it still decides until a sort is chosen from the menu.
    @AppStorage("bcd.library.sort") private var sortKey = ""
    @AppStorage("bcd.library.sortByName") private var sortByName = false
    @State private var searching = false
    @State private var query = ""
    @FocusState private var typing: Bool
    @State private var opened: BCDGame?
    @Environment(\.bcdMenu) private var menu
    @EnvironmentObject private var focus: BCDFocus
    /// MCD: the page shown and the controller's way through the cards and the toolbar.
    @ObservedObject private var nav = MCDLibraryNav.shared

    private var filter: BCDLibraryFilter { BCDLibraryFilter.allCases.first { $0.rawValue == filterKey } ?? .all }
    private var sort: BCDLibrarySort { BCDLibrarySort(rawValue: sortKey) ?? (sortByName ? .name : .played) }
    /// The launcher whose chip is chosen (BCDLaunchers.swift); nil for every other filter.
    private var launcher: BCDLauncherSpec? {
        if case .launcher(let id) = filter { return BCDLauncherSpec.spec(id) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            filters
            if searching { searchField }
            // MCD: Claw Deck's Library -- a grid of whole pages (LT/RT, "Page 1 of 3"), not a free-scrolling one.
            // Every card on the page exists, so the controller's ring can never land on a card that is not there,
            // and the page's columns are the navigator's columns (MCDLibraryNav).
            Group {
                if let launcher { BCDLauncherPanel(spec: launcher) }   // a launcher's chip (Battle.net, EA app): its Install / Open card, no games
                notices
                savesNotice
            }
            .padding(.horizontal, layout.gutter)
            GeometryReader { proxy in
                pagedGrid(in: proxy.size)
            }
            .bcdGlowLayer()
            if nav.pages > 1 { pageBar }
        }
        .onChange(of: filterKey) { _, _ in nav.page = 0; publishToolbar() }
        .onChange(of: query) { _, _ in nav.page = 0 }
        .onChange(of: sortKey) { _, _ in nav.page = 0 }
        .onAppear { publishToolbar() }
        .onChange(of: availableFilters.map(\.rawValue)) { _, _ in publishToolbar() }
        .padding(.top, 4)
        .bcdGamePage($opened, from: "Library")
        // The game menu's "Game page" opens the page over the Library.
        .onAppear { menu?.openPage = { opened = $0 } }
        .onChange(of: searchRequest) { _, _ in toggleSearch() }
    }

    // MARK: Filters and the row's buttons

    /// The filters scroll sideways; Add a game, the order, Search and Refresh stay in sight at the end
    /// of the row (Add a game and the order as round buttons alone on an upright phone).
    private var filters: some View {
        HStack(spacing: 8) {
            chips
            rowButton("library.add", "Add a game", "plus") { store.actions?.addGameFromFiles() }
            rowButton("library.sort", sort.title, "arrow.up.arrow.down", label: "Sort by: \(sort.title)") { showSortMenu() }
            round("library.search", searching ? "xmark" : "magnifyingglass", searching ? "Close the search" : "Search") { toggleSearch() }
            round("library.refresh", "arrow.clockwise", "Refresh the library") { store.actions?.refreshLibrary() }
        }
        .padding(.trailing, layout.gutter)
    }

    private var chips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(availableFilters) { item in
                        Button { filterKey = item.rawValue } label: {
                            Text(item.isLauncher ? item.title : "\(item.title) · \(count(item))")
                                .font(BCDStyle.label(14))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .foregroundStyle(filter == item ? BCDStyle.text : BCDStyle.textSoft)
                                .background(filter == item ? BCDStyle.surfaceRaised : Color.clear, in: Capsule())
                                .overlay(Capsule().strokeBorder(filter == item ? AnyShapeStyle(BCDStyle.glow) : AnyShapeStyle(BCDStyle.stroke),
                                                                lineWidth: filter == item ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                        .bcdFocusable("library.filter.\(item.rawValue)", cornerRadius: 18) { filterKey = item.rawValue }
                        .id(item.rawValue)
                    }
                }
                .padding(.leading, layout.gutter).padding(.trailing, 4).padding(.vertical, 6)
            }
            // The launchers' chips sit at the end of a row that scrolls: a chosen one is brought into view (the other chips stay where they were).
            .onAppear { if filter.isLauncher { proxy.scrollTo(filter.rawValue, anchor: .center) } }
            .onChange(of: filterKey) { _, _ in if filter.isLauncher { proxy.scrollTo(filter.rawValue, anchor: .center) } }
            // MCD: the chip under the controller's ring is always in view.
            .onChange(of: focus.focused) { _, id in
                guard focus.controllerActive, let id, id.hasPrefix("library.filter.") else { return }
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(String(id.dropFirst("library.filter.".count)), anchor: .center) }
            }
            // MCD: the strip ends in a soft fade before the buttons, so no chip reads as sliding under them.
            .mask(HStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 28)
            })
            .padding(.trailing, 4)
        }
    }

    private func round(_ id: String, _ symbol: String, _ label: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(BCDStyle.text)
                .frame(width: 38, height: 38)
                .background(BCDStyle.surface, in: Circle())
                .overlay(Circle().strokeBorder(BCDStyle.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .bcdFocusable(id, cornerRadius: 19, action: run)
        .accessibilityLabel(label)
    }

    /// A button at the end of the row: a capsule with its words, a round icon on an upright phone. One
    /// view in both, so turning the phone does not replace it (a control that goes takes its ring and
    /// its controller action with it).
    private func rowButton(_ id: String, _ title: String, _ symbol: String, label: String? = nil,
                           _ run: @escaping () -> Void) -> some View {
        let round = layout == .phonePortrait
        return Button(action: run) {
            Group {
                if round {
                    Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                        .frame(width: 38, height: 38)
                } else {
                    Label(title, systemImage: symbol)
                        .font(BCDStyle.label(14))
                        .padding(.horizontal, 14).frame(height: 38)
                }
            }
            .foregroundStyle(BCDStyle.text)
            .background(BCDStyle.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(BCDStyle.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .bcdFocusable(id, cornerRadius: 19, action: run)
        .accessibilityLabel(label ?? title)
    }

    /// Every sort the classic library had, in BCD's own menu (the controller's A on the chip opens it too).
    private func showSortMenu() {
        let current = sort
        menu?.show(BCDMenuContent(title: "Sort by", items: BCDLibrarySort.allCases.map { item in
            BCDMenuItem(id: item.rawValue, title: item.title, symbol: item.symbol, checked: item == current, run: { sortKey = item.rawValue })
        }))
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(BCDStyle.textSoft)
            TextField("Find a game", text: $query)
                .font(BCDStyle.body(16))
                .focused($typing)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(BCDStyle.textSoft)
                }
                .buttonStyle(.plain)
                .bcdFocusable("library.search.clear", cornerRadius: 12) { query = "" }
                .accessibilityLabel("Clear")
            }
            Button("Done") { toggleSearch() }
                .font(BCDStyle.label(14)).buttonStyle(.plain).foregroundStyle(BCDStyle.lavender)
                .bcdFocusable("library.search.done", cornerRadius: 12) { toggleSearch() }
        }
        .padding(.horizontal, 14).frame(height: 44)
        .background(BCDStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(BCDStyle.stroke, lineWidth: 1))
        .padding(.horizontal, layout.gutter)
    }

    /// Opens the search and the keyboard; closes it again, and forgets the words.
    private func toggleSearch() {
        withAnimation(.easeOut(duration: 0.18)) {
            searching.toggle()
            if !searching { query = "" }
        }
        typing = searching
    }

    // MARK: What the library says above and below its games

    @ViewBuilder private var notices: some View {
        let steam = store.accounts.first { $0.store == .steam }
        let steamShown = filter == .all || filter == .store(.steam)
        if steamShown, let steam, steam.available, steam.name == nil {
            Button { store.actions?.signIn(.steam) } label: {
                HStack(spacing: 14) {
                    Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(BCDStyle.lavender)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sign in to Steam").font(BCDStyle.heading(17))
                        Text("Your Steam games show up here, and BCD installs them itself.")
                            .font(BCDStyle.body(14)).foregroundStyle(BCDStyle.textSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(BCDStyle.textSoft)
                }
                .padding(16)
                .frame(maxWidth: 620, alignment: .leading)
                .background(BCDStyle.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(BCDStyle.glow, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .bcdFocusable("library.signin", cornerRadius: 18) { store.actions?.signIn(.steam) }
        } else if steamShown, let steam, steam.name != nil, store.count(.steam) == 0, query.isEmpty {
            Text("There are no Windows games on this Steam account yet. Refresh reads the account's list again.")
                .font(BCDStyle.body(14)).foregroundStyle(BCDStyle.textSoft)
                .fixedSize(horizontal: false, vertical: true)
        } else if steamShown, let steam, steam.name != nil, query.isEmpty,
                  store.games.contains(where: { $0.store == .steam }),
                  !store.games.contains(where: { $0.store == .steam && $0.state.isInstalled }) {
            // round 624 (agent N S10, 2FJV7P): a Steam account with games, none installed: how a Steam game starts
            Text("None of your Steam games is installed yet. Tap one, then Install; BCD downloads it from Steam and Play starts it with Valve's own Steam client.")
                .font(BCDStyle.body(14)).foregroundStyle(BCDStyle.textSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Games whose Steam Cloud saves differ from this device's, one line each as the classic library's
    /// Steam section said it: nothing is replaced until the player picks the copies to keep on the game's page.
    @ViewBuilder private var savesNotice: some View {
        let steamShown = filter == .all || filter == .store(.steam)
        let games = store.savesDiffer.compactMap { id in store.games.first { $0.id == id } }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if steamShown, query.isEmpty, !games.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(games.prefix(3)) { game in
                    Button { opened = game } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.icloud").font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(BCDGameColors.amber)
                            Text("Steam Cloud and this device have different saves for \(game.title). Open its page and pick the copy to keep.")
                                .font(BCDStyle.body(14)).foregroundStyle(BCDStyle.text)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(BCDStyle.textSoft)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .frame(maxWidth: 620, alignment: .leading)
                        .background(BCDStyle.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(BCDGameColors.amber.opacity(0.55), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .bcdFocusable("library.saves.\(game.id)", cornerRadius: 16) { opened = game }
                }
                if games.count > 3 {
                    Text("and \(games.count - 3) more").font(BCDStyle.body(13)).foregroundStyle(BCDStyle.textSoft)
                }
            }
        }
    }

    /// No game added by hand yet (the Wine desktop is always there): say how they get in.
    private var showsDriveHint: Bool {
        (filter == .all || filter == .store(.local)) && query.isEmpty && store.count(.local) <= 1
    }

    private var availableFilters: [BCDLibraryFilter] {
        BCDLibraryFilter.allCases.filter { item in
            switch item {
            case .all, .installed: return true
            case .store(let s): return store.count(s) > 0 || store.accounts.contains { $0.store == s && $0.available }
            case .launcher: return BCDLauncherModel.shared.available
            }
        }
    }

    private func count(_ item: BCDLibraryFilter) -> Int {
        switch item {
        case .all: return store.games.count
        case .installed: return store.installedCount
        case .store(let s): return store.count(s)
        case .launcher: return 0
        }
    }

    private var shown: [BCDGame] {
        var list = store.games.filter { game in
            switch filter {
            case .all: return true
            case .installed: return game.state.isInstalled
            case .store(let s): return game.store == s
            case .launcher: return false   // a launcher's chip shows its card, not games
            }
        }
        let words = query.trimmingCharacters(in: .whitespaces)
        if !words.isEmpty { list = list.filter { $0.title.localizedCaseInsensitiveContains(words) } }
        return sort.sorted(list)
    }

    // MARK: The grid

    /// Covers about 100 points wide on a phone on its side (six on an iPhone 13 Pro, seven on a
    /// Pro Max), three across upright, and larger ones on an iPad.
    // MARK: MCD: the paged grid

    /// One page of cards, sized from the room it has: as many columns as fit at the old grid's minimum width,
    /// more while fewer than two rows would fit (Claw Deck shows two rows), and as many whole rows as fit.
    private func pagedGrid(in size: CGSize) -> some View {
        let g = MCDLibraryGrid(size: size, gutter: layout.gutter, layout: layout)
        let all = shown
        let perPage = g.columns * g.rows
        let pages = max(1, (all.count + perPage - 1) / perPage)
        let page = min(max(nav.page, 0), pages - 1)
        let slice = Array(all.dropFirst(page * perPage).prefix(perPage))
        let rowCount = (slice.count + g.columns - 1) / g.columns
        let key = MCDLibraryNav.Layout(ids: all.map { "library.game.\($0.id)" }, columns: g.columns, rows: g.rows)
        return VStack(alignment: .leading, spacing: g.rowSpacing) {
            ForEach(0..<rowCount, id: \.self) { row in
                HStack(alignment: .top, spacing: g.spacing) {
                    ForEach(slice[(row * g.columns)..<min((row + 1) * g.columns, slice.count)]) { game in
                        BCDCoverCard(game: game, focusID: "library.game.\(game.id)") { opened = game }
                            .frame(width: g.cardWidth)
                    }
                }
            }
            if !query.isEmpty && all.isEmpty {
                Text("No game called \"\(query)\" here.").font(BCDStyle.body(15)).foregroundStyle(BCDStyle.textSoft)
            }
            if showsDriveHint {
                Label("To add a game of your own, copy its folder into BCD › wine › drive_c with the Files app, then choose Add a game.",
                      systemImage: "folder.badge.plus")
                    .font(BCDStyle.body(14)).foregroundStyle(BCDStyle.textSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .id(page)
        .transition(.opacity.combined(with: .offset(y: 24)))
        .padding(.horizontal, layout.gutter).padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        // Touch: a swipe up or down turns the page.
        .gesture(DragGesture(minimumDistance: 30).onEnded { value in
            let dy = value.translation.height
            guard abs(dy) > 60, abs(dy) > abs(value.translation.width) else { return }
            nav.turn(dy < 0 ? 1 : -1)
        })
        .onAppear { nav.update(key) }
        .onChange(of: key) { _, new in nav.update(new) }
    }

    /// Claw Deck's page line: LT, the page's dots, "Page 2 of 5 · 15-28 of 128", RT.
    private var pageBar: some View {
        HStack(spacing: 14) {
            pageButton("LT", "Previous page", enabled: nav.page > 0) { nav.turn(-1) }
            HStack(spacing: 6) {
                ForEach(0..<min(nav.pages, 12), id: \.self) { i in
                    Circle().fill(i == nav.page ? Color.white : Color.white.opacity(0.3)).frame(width: 7, height: 7)
                }
            }
            Text("Page \(nav.page + 1) of \(nav.pages)").font(BCDStyle.label(15))
            Text(nav.rangeText).font(BCDStyle.body(14)).foregroundStyle(BCDStyle.textSoft)
            pageButton("RT", "Next page", enabled: nav.page < nav.pages - 1) { nav.turn(1) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, layout.gutter).padding(.bottom, 6)
    }

    private func pageButton(_ glyph: String, _ label: String, enabled: Bool, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(glyph).font(.system(size: 12, weight: .bold))
                .foregroundStyle(enabled ? BCDStyle.text : BCDStyle.textSoft.opacity(0.5))
                .frame(width: 38, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    /// The toolbar in the order Left and Right walk it: every chip, then Add a game, the order, Search, Refresh.
    private func publishToolbar() {
        nav.toolbar = availableFilters.map { "library.filter.\($0.rawValue)" }
            + ["library.add", "library.sort", "library.search", "library.refresh"]
        nav.toolbarHome = "library.filter.\(filter.rawValue)"
    }
}

/// MCD: a Library page's geometry.
struct MCDLibraryGrid {
    let columns: Int, rows: Int
    let cardWidth: CGFloat, spacing: CGFloat, rowSpacing: CGFloat

    init(size: CGSize, gutter: CGFloat, layout: BCDLayout) {
        let sp: CGFloat = layout == .pad ? 20 : 14
        let rsp: CGFloat = layout == .pad ? 22 : 16
        let usableW = size.width - 2 * gutter, usableH = size.height - 10
        var cols = 3, rowsFit = 1, width: CGFloat = 100
        if usableW.isFinite, usableH.isFinite, usableW > 120, usableH > 120 {
            let minimum: CGFloat = layout == .pad ? 132 : 96
            cols = layout == .phonePortrait ? 3 : max(2, Int((usableW + sp) / (minimum + sp)))
            while true {
                width = (usableW - sp * CGFloat(cols - 1)) / CGFloat(cols)
                let height = width * 1.5 + 45   // a 2:3 cover and its two lines
                rowsFit = Int((usableH + rsp) / (height + rsp))
                if rowsFit >= 2 || cols >= 10 { break }
                cols += 1
            }
        }
        spacing = sp
        rowSpacing = rsp
        columns = cols
        rows = max(rowsFit, 1)
        cardWidth = max(width, 40)
    }
}

/// MCD: the Library's controller navigation (Claw Deck's). The shell asks it to steer the D-pad while the Library
/// is up (BCDFrontEnd.installButtons). On a card: Left/Right a card (across rows and pages), Up/Down a row (Down
/// from a page's last row turns to the next page; Up from the very first row goes to the toolbar). On the toolbar:
/// Left/Right walk every chip and button in order, Down returns to the cards. Each move is logged ([mcd-nav]).
@MainActor final class MCDLibraryNav: ObservableObject {
    static let shared = MCDLibraryNav()

    struct Layout: Equatable { var ids: [String]; var columns: Int; var rows: Int }

    @Published var page = 0
    @Published private(set) var pages = 1
    private(set) var ids: [String] = []
    private(set) var columns = 1
    private(set) var rows = 1
    var toolbar: [String] = []
    var toolbarHome = ""
    private var lastCard: String?
    private var perPage: Int { max(columns * rows, 1) }

    var rangeText: String {
        guard !ids.isEmpty else { return "" }
        let first = page * perPage + 1, last = min((page + 1) * perPage, ids.count)
        return "\(first)-\(last) of \(ids.count)"
    }

    func update(_ layout: Layout) {
        ids = layout.ids; columns = max(layout.columns, 1); rows = max(layout.rows, 1)
        pages = max(1, (ids.count + perPage - 1) / perPage)
        if page > pages - 1 { page = pages - 1 }
    }

    /// One D-pad press; true when it was the Library's to take.
    func move(_ direction: BCDMove, focus: BCDFocus) -> Bool {
        guard let current = focus.focused else { return false }
        if let t = toolbar.firstIndex(of: current) {
            switch direction {
            case .left: if t > 0 { go(toolbar[t - 1], focus, direction) }
            case .right: if t < toolbar.count - 1 { go(toolbar[t + 1], focus, direction) }
            case .down:
                let onPage = lastCard.flatMap { ids.firstIndex(of: $0) }.map { $0 / perPage == page } ?? false
                if onPage, let card = lastCard { go(card, focus, direction) }
                else if page * perPage < ids.count { go(ids[page * perPage], focus, direction) }
            case .up: break
            }
            return true
        }
        guard let i = ids.firstIndex(of: current) else { return false }
        let last = ids.count - 1
        switch direction {
        case .left: if i > 0 { go(ids[i - 1], focus, direction) }
        case .right: if i < last { go(ids[i + 1], focus, direction) }
        case .down:
            if i + columns <= last { go(ids[i + columns], focus, direction) }
            else if i / columns < last / columns { go(ids[last], focus, direction) }
        case .up:
            if i - columns >= 0 { go(ids[i - columns], focus, direction) }
            else {
                lastCard = current
                go(toolbar.contains(toolbarHome) ? toolbarHome : (toolbar.first ?? current), focus, direction)
            }
        }
        return true
    }

    /// LT (-1) or RT (+1), or a swipe: the page before or after, the ring on the same place in it.
    func turn(_ delta: Int, focus: BCDFocus? = nil) {
        let target = min(max(page + delta, 0), pages - 1)
        guard target != page else { return }
        let local = (focus?.focused).flatMap { ids.firstIndex(of: $0) }.map { $0 % perPage } ?? 0
        withAnimation(.easeInOut(duration: 0.25)) { page = target }
        if let focus, focus.controllerActive, !ids.isEmpty {
            focus.focused = ids[min(target * perPage + local, ids.count - 1)]
        }
        fputs("[mcd-nav] library page \(page + 1)/\(pages)\n", stderr)
    }

    /// The shell's LT/RT handlers.
    func turnPage(_ delta: Int, focus: BCDFocus) { turn(delta, focus: focus) }

    private func go(_ id: String, _ focus: BCDFocus, _ direction: BCDMove) {
        let from = focus.focused ?? "-"
        if let i = ids.firstIndex(of: id) {
            lastCard = id
            let target = i / perPage
            if target != page { withAnimation(.easeInOut(duration: 0.25)) { page = target } }
        }
        withAnimation(.easeOut(duration: 0.12)) { focus.focused = id }
        fputs("[mcd-nav] library \(direction) \(from) -> \(id) (page \(page + 1)/\(pages), \(columns)x\(rows))\n", stderr)
    }
}

/// The classic library's Sort by choices (Library.swift: "played", "name", "added", "size"), kept
/// by the same words. Ties go by name, then id.
enum BCDLibrarySort: String, CaseIterable, Identifiable {
    case played, name, added, size
    var id: String { rawValue }
    var title: String {
        switch self {
        case .played: return "Last played"
        case .name: return "Name"
        case .added: return "Recently added"
        case .size: return "Folder size"
        }
    }
    var symbol: String {
        switch self {
        case .played: return "clock"
        case .name: return "textformat"
        case .added: return "plus"
        case .size: return "internaldrive"
        }
    }

    /// Last played: the games on this device first, the most recently played at the top. Name: A to Z,
    /// numbers as people count them (Warcraft II before Warcraft III). Recently added: the newest in the
    /// library's list first, games the library has no entry for after them. Folder size: the largest
    /// on disk first, games that are not on this device after them.
    func sorted(_ games: [BCDGame]) -> [BCDGame] {
        games.sorted { a, b in
            switch self {
            case .played:
                if a.state.isInstalled != b.state.isInstalled { return a.state.isInstalled }
                if a.lastPlayed != b.lastPlayed { return (a.lastPlayed ?? .distantPast) > (b.lastPlayed ?? .distantPast) }
            case .added:
                if a.added != b.added { return (a.added ?? -1) > (b.added ?? -1) }
            case .size:
                let sizeA = a.state.isInstalled ? a.size ?? -1 : -1, sizeB = b.state.isInstalled ? b.size ?? -1 : -1
                if sizeA != sizeB { return sizeA > sizeB }
            case .name:
                break
            }
            let order = a.title.localizedStandardCompare(b.title)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
    }
}

enum BCDLibraryFilter: Identifiable, Hashable, CaseIterable {
    case all, installed, store(BCDStoreFront), launcher(String)
    /// The stores' chips, then one chip per launcher (BCDLauncherSpec.shown: Battle.net, EA app; none while they are hidden, build 600).
    static var allCases: [BCDLibraryFilter] {
        [.all, .installed] + BCDStoreFront.allCases.map { .store($0) } + BCDLauncherSpec.shown.map { .launcher($0.id) }
    }
    var id: String { rawValue }
    var rawValue: String {
        switch self {
        case .all: return "all"
        case .installed: return "installed"
        case .store(let s): return s.rawValue
        case .launcher(let id): return "launcher." + id
        }
    }
    var title: String {
        switch self {
        case .all: return "All"
        case .installed: return "Installed"
        case .store(let s): return s.title
        case .launcher(let id): return BCDLauncherSpec.spec(id)?.title ?? id
        }
    }
    var isLauncher: Bool {
        if case .launcher = self { return true }
        return false
    }
}
