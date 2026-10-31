// SPDX-License-Identifier: GPL-3.0-only
// Mobile Claw Deck (MCD), a fork of BCD (https://github.com/thebcd69/bcd-games) by ausfowler.
// Added 2026-10-31. Includes work from BCD by thebcd69.
//
// MCD's Home: Claw Deck 3.0's carousel (ausfowler/rusty-clawdeck, src/ui.rs draw_carousel,
// src/motion.rs, docs/NAVIGATION.md) on BCD's store. The numbers are Claw Deck's:
//   - cards are 2:3, sized min(width * 0.273 / 300, height * 0.46 / 300), centred at 45% height;
//   - a card at distance d from the selection: scale 1.05 - 0.45d (d < 1), else max(0.65 - 0.05d, 0.2);
//     opacity 1 - 0.6d (d < 1), else max(0.5 - 0.1d, 0); 180 units apart; 4.5 cards each side drawn;
//   - A flips the selected card into its info card (2D flip: it squashes edge-on, then shows its back),
//     growing to 484 x 319 units while its neighbours slide 165 units aside and fade 45%;
//   - springs: glide (stiffness 500, damping 30, mass 0.9), flip (260, 26, 1);
//   - the background is the selected game's art, blurred, cross-faded over 0.35 s.
// Left/Right move the selection (on the flipped card: Play or Settings), A flips or confirms, B flips
// back, X opens the game's menu, Y the MCD menu (MCDMenu below). Settings on the card is BCD's whole
// game page (every per-game setting); Play is BCD's own Play.

import SwiftUI

// MARK: - Motion

enum MCDMotion {
    /// Carousel glide: Claw Deck's `{ stiffness: 500, damping: 30, mass: 0.9 }`.
    static let glide = Animation.interpolatingSpring(mass: 0.9, stiffness: 500, damping: 30)
    /// Card flip and grow: `{ stiffness: 260, damping: 26 }`.
    static let flip = Animation.interpolatingSpring(mass: 1, stiffness: 260, damping: 26)
    /// Menus and the tab pill: `{ stiffness: 420, damping: 30 }`.
    static let pop = Animation.interpolatingSpring(mass: 1, stiffness: 420, damping: 30)
}

// MARK: - The model the shell drives

/// What the carousel shows and where it stands. The shell (BCDFrontEnd) owns it, so the controller's
/// buttons, which the shell installs, and the screen share one state; the selection survives
/// leaving Home and coming back, as in Claw Deck.
@MainActor final class MCDCarouselModel: ObservableObject {
    /// The selected game's id (kept by id, so a library that changes keeps the same game selected).
    @Published var selectedID: String? {
        didSet { if let selectedID { UserDefaults.standard.set(selectedID, forKey: Self.key) } }
    }
    /// The selected card is flipped to its info side.
    @Published var expanded = false
    /// On the flipped card: Play (false) or Settings (true).
    @Published var settingsFocused = false

    private static let key = "mcd.home.selected"
    init() { selectedID = UserDefaults.standard.string(forKey: Self.key) }

    /// Claw Deck's order: the most recently played first, then the rest by title.
    static func order(_ games: [BCDGame]) -> [BCDGame] {
        games.sorted { a, b in
            switch (a.lastPlayed, b.lastPlayed) {
            case let (x?, y?): return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            // A plain comparison, no ICU collation (BCD avoids ICU in the interface: BCDFormat).
            default: return a.title.lowercased() < b.title.lowercased()
            }
        }
    }

    func index(in games: [BCDGame]) -> Int {
        guard !games.isEmpty else { return 0 }
        return selectedID.flatMap { id in games.firstIndex { $0.id == id } } ?? 0
    }

    /// Left/Right. On the flipped card they choose Play or Settings; otherwise they glide the carousel.
    func step(_ delta: Int, in games: [BCDGame]) {
        guard !games.isEmpty else { return }
        if expanded {
            withAnimation(.easeOut(duration: 0.14)) { settingsFocused = delta > 0 }
            return
        }
        let next = min(max(index(in: games) + delta, 0), games.count - 1)
        withAnimation(MCDMotion.glide) { selectedID = games[next].id }
    }

    func select(_ id: String) {
        withAnimation(MCDMotion.glide) { selectedID = id }
    }

    func setExpanded(_ on: Bool) {
        withAnimation(MCDMotion.flip) {
            expanded = on
            if on { settingsFocused = false }
        }
    }
}

// MARK: - Home

struct MCDHomeView: View {
    @EnvironmentObject private var store: BCDStore
    @ObservedObject var model: MCDCarouselModel
    /// Play and Settings on the flipped card (the shell's A does the same through the model).
    let play: (BCDGame) -> Void
    let openPage: (BCDGame) -> Void
    @State private var dragged: CGFloat = 0

    var body: some View {
        let games = MCDCarouselModel.order(store.games)
        GeometryReader { proxy in
            ZStack {
                if games.isEmpty {
                    empty
                } else {
                    let selected = model.index(in: games)
                    carousel(games, selected: selected, size: proxy.size)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(swipe(games))
        }
        .background { MCDBackdrop(game: games.isEmpty ? nil : games[model.index(in: games)]) }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Text("YOUR LIBRARY STARTS HERE").font(BCDStyle.caps(26)).tracking(2)
            Text("Press Y, then Add a game, or sign in to a store in Accounts.")
                .font(BCDStyle.body(16)).foregroundStyle(BCDStyle.lavender)
        }
        .multilineTextAlignment(.center)
        .padding(24)
    }

    @ViewBuilder
    private func carousel(_ games: [BCDGame], selected: Int, size: CGSize) -> some View {
        // Claw Deck: card scale from width, bounded by height (Settings › Display › Carousel size is 100%).
        let sc = min(size.width * 0.273 / 300, size.height * 0.46 / 300)
        let center = CGPoint(x: size.width / 2, y: size.height * 0.45)
        let first = max(selected - 5, 0), last = min(selected + 5, games.count - 1)
        // The farther cards first, so the nearer ones draw over them.
        let order = (first...last).sorted { abs($0 - selected) > abs($1 - selected) }
        ZStack {
            ForEach(order, id: \.self) { i in
                let game = games[i]
                let isSelected = i == selected
                MCDCarouselCard(game: game,
                                pos: Double(i - selected) + Double(dragged / (180 * sc)),
                                expand: isSelected && model.expanded ? 1 : 0,
                                neighbourPush: model.expanded ? 1 : 0,
                                sc: sc,
                                selected: isSelected,
                                settingsFocused: model.settingsFocused,
                                play: { play(game) },
                                settings: { openPage(game) })
                    .position(center)
                    .zIndex(isSelected ? 100 : Double(10 - abs(i - selected)))
                    .onTapGesture {
                        if isSelected { model.setExpanded(!model.expanded) }
                        else { model.setExpanded(false); model.select(game.id) }
                    }
            }
            if !model.expanded, games.indices.contains(selected) {
                caption(games[selected])
                    .position(x: center.x, y: center.y + 300 * 1.05 * sc / 2 + 44)
                    .transition(.opacity)
            }
        }
    }

    /// The title and store chip under the selected card (hidden while it is flipped).
    private func caption(_ game: BCDGame) -> some View {
        VStack(spacing: 8) {
            Text(game.title).font(BCDStyle.title(21)).lineLimit(1).minimumScaleFactor(0.7)
            MCDChip(text: game.store.mcdLabel)
        }
        .padding(.horizontal, 24)
    }

    /// A horizontal swipe glides the carousel by the cards it covers, as touch on Claw Deck does.
    private func swipe(_ games: [BCDGame]) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !model.expanded else { return }
                dragged = value.translation.width
            }
            .onEnded { value in
                guard !model.expanded else { dragged = 0; return }
                let predicted = value.predictedEndTranslation.width
                let cards = Int((-predicted / 140).rounded())
                withAnimation(MCDMotion.glide) {
                    dragged = 0
                    if cards != 0 { model.step(cards, in: games) }
                }
            }
    }
}

// MARK: - One card

/// A carousel card at `pos` (cards from the selection, fractional while gliding) and `expand`
/// (0 = cover, 1 = flipped open). Both animate: the view is Animatable, so the springs drive
/// the same geometry Claw Deck draws each frame.
struct MCDCarouselCard: View, Animatable {
    let game: BCDGame
    var pos: Double
    var expand: Double
    var neighbourPush: Double
    let sc: CGFloat
    let selected: Bool
    let settingsFocused: Bool
    let play: () -> Void
    let settings: () -> Void

    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { AnimatablePair(pos, AnimatablePair(expand, neighbourPush)) }
        set { pos = newValue.first; expand = newValue.second.first; neighbourPush = newValue.second.second }
    }

    var body: some View {
        let d = abs(pos)
        var scale = d < 1 ? 1.05 - 0.45 * d : max(0.65 - 0.05 * d, 0.2)
        scale += (1 - scale) * expand
        var opacity = d < 1 ? 1 - 0.6 * d : max(0.5 - 0.1 * d, 0)
        if !selected { opacity *= 1 - 0.45 * neighbourPush }
        let push = selected ? 0 : (pos == 0 ? 0 : (pos > 0 ? 1.0 : -1.0)) * 165 * neighbourPush
        let width = (200 + 284 * expand) * sc * scale
        let height = (300 + 19 * expand) * sc * scale
        let flip = cos(expand * .pi)
        let radius = (12 + 4 * expand) * sc * scale
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        return Group {
            if flip >= 0 {
                front(shape: shape, width: width, height: height)
            } else {
                back(shape: shape, width: width, height: height, reveal: min(max((abs(flip) - 0.55) / 0.45, 0), 1))
            }
        }
        .frame(width: width, height: height)
        .scaleEffect(x: 1, y: max(abs(flip), 0.02))
        .offset(x: (pos * 180 + push) * sc)
        .opacity(opacity)
        .allowsHitTesting(opacity > 0.05)
    }

    private func front(shape: RoundedRectangle, width: CGFloat, height: CGFloat) -> some View {
        BCDGameArt(game: game, kind: .cover)
            .frame(width: width, height: height)
            .clipShape(shape)
            .overlay {
                if selected {
                    shape.strokeBorder(Color.white.opacity(0.9), lineWidth: max(3 * sc, 2))
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 26 * sc, y: 10 * sc)
            .shadow(color: selected ? Color.white.opacity(0.24) : .clear, radius: 30 * sc)
    }

    private func back(shape: RoundedRectangle, width: CGFloat, height: CGFloat, reveal: Double) -> some View {
        let s = sc
        return HStack(alignment: .center, spacing: 34 * s) {
            BCDGameArt(game: game, kind: .cover, showTitle: false)
                .frame(width: 200 * s, height: 300 * s)
                .clipShape(RoundedRectangle(cornerRadius: 10 * s, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 14 * s, y: 6 * s)
            VStack(alignment: .leading, spacing: 12 * s) {
                Text(game.title).font(BCDStyle.title(30 * s)).lineLimit(2).minimumScaleFactor(0.6)
                MCDChip(text: game.store.mcdLabel)
                BCDGameStatusLine(game: game)
                HStack(alignment: .top, spacing: 26 * s) {
                    fact("Last played", game.lastPlayed.map { BCDFormat.ago($0) } ?? "Never")
                    if let size = game.size { fact(game.state.isInstalled ? "Installed" : "Download", BCDFormat.bytes(size)) }
                    if game.minutesPlayed > 0 { fact("Played", MCDFormat.minutes(game.minutesPlayed)) }
                }
                HStack(spacing: 12 * s) {
                    Button(action: play) {
                        Label(game.state.isInstalled ? "Play" : "Install", systemImage: game.state.isInstalled ? "play.fill" : "arrow.down")
                            .font(BCDStyle.label(19 * s))
                            .frame(maxWidth: .infinity, minHeight: 46 * s)
                            .bcdFocusRing(!settingsFocused, cornerRadius: 12 * s)
                    }
                    Button(action: settings) {
                        Label("Settings", systemImage: "gearshape.fill")
                            .font(BCDStyle.label(19 * s))
                            .frame(minWidth: 120 * s, minHeight: 46 * s)
                            .padding(.horizontal, 10 * s)
                            .background(RoundedRectangle(cornerRadius: 12 * s, style: .continuous).fill(Color.white.opacity(0.06)))
                            .bcdFocusRing(settingsFocused, cornerRadius: 12 * s)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(28 * s)
        .opacity(reveal)
        .frame(width: width, height: height)
        .bcdGlass(cornerRadius: shape.cornerSize.width)
        .shadow(color: .black.opacity(0.55), radius: 50 * s, y: 16 * s)
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3 * sc) {
            Text(title).font(BCDStyle.body(14 * sc)).foregroundStyle(BCDStyle.textSoft)
            Text(value).font(BCDStyle.label(17 * sc)).lineLimit(1)
        }
    }
}

// MARK: - Pieces

/// The selected game's art behind everything: blurred, dimmed toward ink, cross-faded on change.
struct MCDBackdrop: View {
    let game: BCDGame?
    var body: some View {
        ZStack {
            BCDStyle.ink
            if let game {
                BCDGameArt(game: game, kind: .hero, showTitle: false)
                    .scaledToFill()
                    .blur(radius: 36)
                    .opacity(0.55)
                    .id(game.id)
                    .transition(.opacity)
            }
            LinearGradient(colors: [BCDStyle.ink.opacity(0.35), BCDStyle.ink.opacity(0.15), BCDStyle.ink.opacity(0.85)],
                           startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.35), value: game?.id)
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Claw Deck's small platform chip ("STEAM").
struct MCDChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(BCDStyle.caps(12)).tracking(1.6)
            .foregroundStyle(Color(red: 0.847, green: 0.867, blue: 0.890))   // #D8DDE3
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.10)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
    }
}

enum MCDFormat {
    static func minutes(_ value: Int) -> String {
        value < 60 ? "\(value) min" : "\(value / 60) h \(value % 60) min"
    }
    /// "9:41 PM" from BCD's own calendar arithmetic (BCDFormat.civil), never a date formatter.
    static func clock(_ date: Date) -> String {
        let c = BCDFormat.civil(date)
        let hour = c.hour % 12 == 0 ? 12 : c.hour % 12
        return "\(hour):\(c.minute < 10 ? "0" : "")\(c.minute) \(c.hour < 12 ? "AM" : "PM")"
    }
}

extension BCDStoreFront {
    /// The chip's word for a store, from BCD's own name for it ("STEAM", "EPIC GAMES").
    var mcdLabel: String { title.uppercased() }
}
