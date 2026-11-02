// SPDX-License-Identifier: GPL-3.0-only
// Mobile Claw Deck (MCD), a fork of BCD (https://github.com/thebcd69/bcd-games) by ausfowler.
// Added 2026-11-02. Includes work from BCD by thebcd69.
//
// What a game's card offers with Cloud (GeForce NOW), for Home's flipped card (layout A of the
// build plan: Play or Install · Cloud · gear). Plain values: MCDCloudCardsLive.swift (engine-bound)
// answers `lookup` from MCD Cloud's catalog and bumps `revision` when the answers may have changed.
// Signed out, or a game GeForce NOW does not have: nil, and the card is exactly as before.
//
// Phase 4: when each game was last played in the cloud. A card flips open on Cloud when the cloud
// was where the game was last played, and its "Last played" says "· Cloud".

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

    private init() {
        let saved = UserDefaults.standard.dictionary(forKey: Self.playedKey) as? [String: Double] ?? [:]
        cloudPlayed = saved.mapValues { Date(timeIntervalSince1970: $0) }
    }

    func state(_ game: BCDGame) -> MCDCloudCardState? { lookup(game) }

    // MARK: Last played in the cloud (phase 4)

    private static let playedKey = "mcd.cloud.lastPlayed"
    /// By MCD's game id: the last moment its stream was on screen.
    private(set) var cloudPlayed: [String: Date]

    /// The game's stream was on screen just now (MCDCloudPlay: when it starts and when it stops).
    func notePlayed(_ id: String, at date: Date = Date()) {
        cloudPlayed[id] = date
        UserDefaults.standard.set(cloudPlayed.mapValues(\.timeIntervalSince1970), forKey: Self.playedKey)
        changed()
    }

    /// Steam records a cloud session too (GeForce NOW plays on your Steam account), when the game quits there:
    /// shortly after the stream left the screen. A Steam date up to this long after MCD's is that same session.
    static let sameSession: TimeInterval = 15 * 60

    /// When the game was last played, and whether that was in the cloud.
    func lastPlayed(_ game: BCDGame) -> (date: Date, cloud: Bool)? {
        Self.lastPlayed(device: game.lastPlayed, cloud: cloudPlayed[game.id])
    }

    static func lastPlayed(device: Date?, cloud: Date?) -> (date: Date, cloud: Bool)? {
        guard let cloud else { return device.map { (date: $0, cloud: false) } }
        guard let device, device > cloud.addingTimeInterval(sameSession) else { return (date: cloud, cloud: true) }
        return (date: device, cloud: false)
    }

    /// The flipped card opens on Cloud: it has Cloud, and the cloud is where it was last played.
    func opensOnCloud(_ game: BCDGame) -> Bool {
        state(game) != nil && lastPlayed(game)?.cloud == true
    }

    func changed() { revision &+= 1 }

    /// The buttons a game's flipped card shows, in order.
    func buttons(_ game: BCDGame) -> [MCDCardButton] {
        state(game) == nil ? [.main, .settings] : [.main, .cloud, .settings]
    }
}
