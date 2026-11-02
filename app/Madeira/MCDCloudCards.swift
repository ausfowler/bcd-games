// SPDX-License-Identifier: GPL-3.0-only
// Mobile Claw Deck (MCD), a fork of BCD (https://github.com/thebcd69/bcd-games) by ausfowler.
// Added 2026-11-02. Includes work from BCD by thebcd69.
//
// What a game's card offers with Cloud (GeForce NOW), for Home's flipped card (layout A of the
// build plan: Play or Install · Cloud · gear). Plain values: MCDCloudCardsLive.swift (engine-bound)
// answers `lookup` from MCD Cloud's catalog and bumps `revision` when the answers may have changed.
// Signed out, or a game GeForce NOW does not have: nil, and the card is exactly as before.

import SwiftUI

/// The Cloud button of one game's card.
enum MCDCloudCardState: Equatable {
    /// GeForce NOW plays it: the button says Cloud (the hint bar, "Play with Cloud").
    case ready
    /// GeForce NOW has it for a store not linked to the account: the button says "Link <store>".
    case link(store: String, label: String)
}

/// The three buttons of the flipped card, left to right.
enum MCDCardButton: Equatable {
    case main       // Play or Install
    case cloud      // only when the game has a Cloud state
    case settings   // the game's page
}

@MainActor final class MCDCloudCards: ObservableObject {
    static let shared = MCDCloudCards()

    /// Changes when the answers may have changed (catalog, library or linked stores refreshed).
    @Published private(set) var revision = 0
    /// The live side's answer for a game; nil until it is installed (no Cloud anywhere).
    var lookup: (BCDGame) -> MCDCloudCardState? = { _ in nil }
    /// Links the store a `.link` state names.
    var link: (String) -> Void = { _ in }

    private init() {}

    func state(_ game: BCDGame) -> MCDCloudCardState? { lookup(game) }

    func changed() { revision &+= 1 }

    /// The buttons a game's flipped card shows, in order.
    func buttons(_ game: BCDGame) -> [MCDCardButton] {
        state(game) == nil ? [.main, .settings] : [.main, .cloud, .settings]
    }
}
