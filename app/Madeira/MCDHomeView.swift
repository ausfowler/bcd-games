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
    /// On the flipped card: the button the ring is on (Play or Install, Cloud, Settings).
    @Published var cardButton: MCDCardButton = .main
    /// Settings is the one the ring is on (the shell's older name for it).
    var settingsFocused: Bool { cardButton == .settings }

    private static let key = "mcd.home.selected"
    init() { selectedID = UserDefaults.standard.string(forKey: Self.key) }

    /// Claw Deck's order: the most recently played first (MCD Cloud: in the cloud too), then the rest by title.
    static func order(_ games: [BCDGame]) -> [BCDGame] {
        let cards = MCDCloudCards.shared
        return games.sorted { a, b in
            switch (cards.lastPlayed(a)?.date, cards.lastPlayed(b)?.date) {
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

    /// Left/Right. On the flipped card they step through its buttons (Play or Install, Cloud when the
    /// game has it, Settings), stopping at the ends; otherwise they glide the carousel.
    func step(_ delta: Int, in games: [BCDGame]) {
        guard !games.isEmpty else { return }
        if expanded {
            let game = games[index(in: games)]
            let buttons = MCDCloudCards.shared.buttons(game)
            let at = buttons.firstIndex(of: button(for: game)) ?? 0
            let next = buttons[min(max(at + delta, 0), buttons.count - 1)]
            withAnimation(.easeOut(duration: 0.14)) { cardButton = next }
            return
        }
        let next = min(max(index(in: games) + delta, 0), games.count - 1)
        withAnimation(MCDMotion.glide) { selectedID = games[next].id }
    }

    /// The button the ring is on for this game: Cloud falls back to Play when the game has no Cloud
    /// (signed out meanwhile, or the catalog changed).
    func button(for game: BCDGame) -> MCDCardButton {
        cardButton == .cloud && MCDCloudCards.shared.state(game) == nil ? .main : cardButton
    }

    func select(_ id: String) {
        withAnimation(MCDMotion.glide) { selectedID = id }
    }

    /// `game`: the card that flips open; it opens on Cloud when the cloud is where it was last played (phase 4).
    func setExpanded(_ on: Bool, game: BCDGame? = nil) {
        withAnimation(MCDMotion.flip) {
            expanded = on
            if on { cardButton = game.map { MCDCloudCards.shared.opensOnCloud($0) } == true ? .cloud : .main }
        }
    }
}

// MARK: - Home

struct MCDHomeView: View {
    @EnvironmentObject private var store: BCDStore
    @ObservedObject var model: MCDCarouselModel
    /// Play, Cloud and Settings on the flipped card (the shell's A does the same through the model).
    let play: (BCDGame) -> Void
    let cloud: (BCDGame) -> Void
    let openPage: (BCDGame) -> Void
    /// Each card's Cloud button (MCDCloudCards): redrawn when the catalog or the account changes.
    @ObservedObject private var cloudCards = MCDCloudCards.shared
    @State private var dragged: CGFloat = 0

    var body: some View {
        let games = MCDCarouselModel.order(store.games)
        GeometryReader { proxy in
            ZStack {
                if games.isEmpty {
                    empty
                } else if proxy.size.width < 80 || proxy.size.height < 80 {
                    // The first layout pass can be zero-sized: no card is drawn until there is room, so no
                    // scale of 0 ever reaches a division (a NaN position ends the app: CALayerInvalidGeometry).
                    Color.clear
                } else {
                    let selected = model.index(in: games)
                    carousel(games, selected: selected, size: proxy.size)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            // A tap anywhere off the flipped card turns it back (its own buttons and its face keep theirs).
            .onTapGesture { if model.expanded { model.setExpanded(false) } }
            .gesture(swipe(games))
        }
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
        // Claw Deck sizes cards min(width * 0.273, height * 0.46) / 300 for a large handheld screen; on a phone that
        // made them small, so MCD uses more of the screen: 36% of the width in landscape (55% upright), 60% of the height.
        let portrait = size.height > size.width
        let sc = max(min(size.width * (portrait ? 0.55 : 0.36) / 300, size.height * 0.60 / 300), 0.05)
        // The flipped card is 540 x 300 units; it never outgrows the screen (the narrow folded Duo, upright).
        let backScale = max(min(sc * 1.05, (size.width - 32) / 540, (size.height - 24) / 300), 0.05)
        // The finger's travel in cards (0 when the scale is not usable).
        let drag = MCDMath.finite(Double(dragged / (180 * sc)))
        let center = CGPoint(x: size.width / 2, y: size.height * 0.45)
        let first = max(selected - 5, 0), last = min(selected + 5, games.count - 1)
        // The farther cards first, so the nearer ones draw over them.
        let order = (first...last).sorted { abs($0 - selected) > abs($1 - selected) }
        ZStack {
            ForEach(order, id: \.self) { i in
                let game = games[i]
                let isSelected = i == selected
                MCDCarouselCard(game: game,
                                pos: Double(i - selected) + drag,
                                expand: isSelected && model.expanded ? 1 : 0,
                                neighbourPush: model.expanded ? 1 : 0,
                                sc: sc,
                                backScale: backScale,
                                selected: isSelected,
                                focused: isSelected ? model.button(for: game) : .main,
                                cloudState: isSelected ? cloudCards.state(game) : nil,
                                play: { play(game) },
                                cloud: { cloud(game) },
                                settings: { openPage(game) })
                    .position(center)
                    .zIndex(isSelected ? 100 : Double(10 - abs(i - selected)))
                    .onTapGesture {
                        if isSelected { model.setExpanded(!model.expanded, game: game) }
                        else if model.expanded { model.setExpanded(false) }   // off the flipped card: back to the carousel
                        else { model.select(game.id) }
                    }
            }
            if !model.expanded, games.indices.contains(selected) {
                caption(games[selected])
                    .position(x: center.x, y: min(center.y + 300 * 1.05 * sc / 2 + 48, size.height - 40))
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
    /// The flipped card's own scale (540 x 300 units, fitted to the screen).
    let backScale: CGFloat
    let selected: Bool
    /// The flipped card's button the ring is on.
    let focused: MCDCardButton
    /// Its Cloud button (layout A: Play or Install · Cloud · gear); nil: Play · Settings, as before.
    let cloudState: MCDCloudCardState?
    let play: () -> Void
    let cloud: () -> Void
    let settings: () -> Void

    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { AnimatablePair(pos, AnimatablePair(expand, neighbourPush)) }
        set { pos = newValue.first; expand = newValue.second.first; neighbourPush = newValue.second.second }
    }

    var body: some View {
        let pos = MCDMath.finite(self.pos), expand = min(max(MCDMath.finite(self.expand), 0), 1)
        let neighbourPush = min(max(MCDMath.finite(self.neighbourPush), 0), 1)
        let d = abs(pos)
        var scale = d < 1 ? 1.05 - 0.45 * d : max(0.65 - 0.05 * d, 0.2)
        scale += (1 - scale) * expand
        var opacity = d < 1 ? 1 - 0.6 * d : max(0.5 - 0.1 * d, 0)
        if !selected { opacity *= 1 - 0.45 * neighbourPush }
        let push = selected ? 0 : (pos == 0 ? 0 : (pos > 0 ? 1.0 : -1.0)) * 165 * neighbourPush
        // The cover's size grows into the flipped card's: Claw Deck's flip, with a wider back (540 x 300 units) so its
        // text column has room (the 484-unit back gave the text 40% of the card and cut words short).
        let width = 200 * sc * scale * (1 - expand) + 540 * backScale * expand
        let height = 300 * sc * scale * (1 - expand) + 300 * backScale * expand
        let flip = cos(expand * .pi)
        let radius = 12 * sc * scale * (1 - expand) + 16 * backScale * expand
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
        let s = backScale
        return HStack(alignment: .center, spacing: 24 * s) {
            // The cover keeps about 28% of the card (Claw Deck's back gives it about 30%).
            BCDGameArt(game: game, kind: .cover, showTitle: false)
                .frame(width: 150 * s, height: 225 * s)
                .clipShape(RoundedRectangle(cornerRadius: 10 * s, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 14 * s, y: 6 * s)
            VStack(alignment: .leading, spacing: 9 * s) {
                // Two lines before it shrinks; never cut short.
                Text(game.title).font(BCDStyle.title(27 * s)).lineLimit(2).minimumScaleFactor(0.75)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10 * s) {
                    MCDChip(text: game.store.mcdLabel)
                    BCDGameStatusLine(game: game).font(BCDStyle.body(14 * s))
                }
                HStack(alignment: .top, spacing: 22 * s) {
                    // MCD Cloud (phase 4): "Today · Cloud" when the cloud is where it was last played.
                    fact("Last played", MCDCloudCards.shared.lastPlayed(game).map { BCDFormat.ago($0.date) + ($0.cloud ? " · Cloud" : "") } ?? "Never")
                    if game.minutesPlayed > 0 { fact("Played", BCDFormat.playtime(game.minutesPlayed)) }
                    if let size = game.size { fact(game.state.isInstalled ? "Installed" : "Download", BCDFormat.bytes(size)) }
                }
                Spacer(minLength: 4 * s)
                // Without Cloud: Play 55%, Settings 45%, both labels whole ("Settings" was cut to "Setti...").
                // With Cloud (layout A): Play or Install, Cloud, and Settings as a 44-unit gear; Play keeps 55%
                // of what is left, so it stays the widest button.
                GeometryReader { row in
                    let gap = 10 * s
                    let gear = 44 * s
                    let usable = max(row.size.width - gap * (cloudState == nil ? 1 : 2), 2)
                    let rest = max(usable - (cloudState == nil ? 0 : gear), 2)
                    HStack(spacing: gap) {
                        Button(action: play) {
                            HStack(spacing: 7 * s) {
                                Image(systemName: game.state.isInstalled ? "play.fill" : "arrow.down").font(.system(size: 16 * s, weight: .bold))
                                Text(game.state.isInstalled ? "Play" : "Install").font(BCDStyle.label(18 * s))
                            }
                            .lineLimit(1).minimumScaleFactor(0.5)
                            .frame(width: rest * 0.55, height: 44 * s)
                            .bcdFocusRing(focused == .main, cornerRadius: 12 * s)
                        }
                        if let cloudState {
                            Button(action: cloud) {
                                HStack(spacing: 6 * s) {
                                    Image(systemName: cloudSymbol(cloudState)).font(.system(size: 15 * s, weight: .semibold))
                                    Text(cloudTitle(cloudState)).font(BCDStyle.label(16 * s))
                                }
                                .lineLimit(1).minimumScaleFactor(0.5)
                                .frame(width: rest * 0.45, height: 44 * s)
                                .background(RoundedRectangle(cornerRadius: 12 * s, style: .continuous).fill(Color.white.opacity(0.06)))
                                .bcdFocusRing(focused == .cloud, cornerRadius: 12 * s)
                            }
                            .accessibilityLabel(cloudState == .ready ? "Play with Cloud" : cloudTitle(cloudState))
                            Button(action: settings) {
                                Image(systemName: "gearshape.fill").font(.system(size: 17 * s, weight: .semibold))
                                    .frame(width: gear, height: 44 * s)
                                    .background(RoundedRectangle(cornerRadius: 12 * s, style: .continuous).fill(Color.white.opacity(0.06)))
                                    .bcdFocusRing(focused == .settings, cornerRadius: 12 * s)
                            }
                            .accessibilityLabel("Settings")
                        } else {
                            Button(action: settings) {
                                HStack(spacing: 6 * s) {
                                    Image(systemName: "gearshape.fill").font(.system(size: 14 * s, weight: .semibold))
                                    Text("Settings").font(BCDStyle.label(16 * s))
                                }
                                .lineLimit(1).minimumScaleFactor(0.5)
                                .frame(width: usable * 0.45, height: 44 * s)
                                .background(RoundedRectangle(cornerRadius: 12 * s, style: .continuous).fill(Color.white.opacity(0.06)))
                                .bcdFocusRing(focused == .settings, cornerRadius: 12 * s)
                            }
                        }
                    }
                }
                .frame(height: 44 * s)
                .buttonStyle(.plain)
                .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, maxHeight: 225 * s, alignment: .leading)
        }
        .padding(.horizontal, 24 * s).padding(.vertical, 20 * s)
        .opacity(reveal)
        .frame(width: width, height: height)
        .bcdGlass(cornerRadius: shape.cornerSize.width)
        .shadow(color: .black.opacity(0.55), radius: 50 * s, y: 16 * s)
    }

    private func cloudTitle(_ state: MCDCloudCardState) -> String {
        switch state {
        case .ready: return "Cloud"
        case .link(_, let label): return "Link \(label)"
        }
    }

    private func cloudSymbol(_ state: MCDCloudCardState) -> String {
        state == .ready ? "cloud.fill" : "link"
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3 * backScale) {
            Text(title).font(BCDStyle.body(13 * backScale)).foregroundStyle(BCDStyle.textSoft).lineLimit(1)
            Text(value).font(BCDStyle.label(16 * backScale)).lineLimit(1).minimumScaleFactor(0.6)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Pieces

/// The selected game's art behind everything: blurred, dimmed toward ink, cross-faded on change.
struct MCDBackdrop: View {
    let game: BCDGame?
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                BCDStyle.ink
                if let game {
                    BCDGameArt(game: game, kind: .hero, showTitle: false)
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .blur(radius: 36)
                        .opacity(0.55)
                        .id(game.id)
                        .transition(.opacity)
                }
                LinearGradient(colors: [BCDStyle.ink.opacity(0.35), BCDStyle.ink.opacity(0.15), BCDStyle.ink.opacity(0.85)],
                               startPoint: .top, endPoint: .bottom)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .animation(.easeInOut(duration: 0.35), value: game?.id)
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

/// Every number that reaches a frame, an offset or a position goes through here: SwiftUI hands a
/// NaN or an infinity on to Core Animation, which ends the app (CALayerInvalidGeometry).
enum MCDMath {
    static func finite(_ value: Double, _ fallback: Double = 0) -> Double { value.isFinite ? value : fallback }
    static func finite(_ value: CGFloat, _ fallback: CGFloat = 0) -> CGFloat { value.isFinite ? value : fallback }
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
