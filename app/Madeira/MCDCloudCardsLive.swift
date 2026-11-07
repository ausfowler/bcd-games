// SPDX-License-Identifier: GPL-3.0-only
// Mobile Claw Deck (MCD), a fork of BCD (https://github.com/thebcd69/bcd-games) by ausfowler.
// Added 2026-11-02. Includes work from BCD by thebcd69.
//
// MCDCloudCards on the engine: each card's Cloud state from MCD Cloud's catalog (app/MCDCloud).
// A Steam game (id "steam.<appID>", BCDLiveID) is found by its app ID, then by its title among
// GeForce NOW's Steam versions; an Epic or GOG game by its title among that store's versions; a
// game added from Files by its title among any. Engine-bound (tools/ui-preview.py, ENGINE_BOUND).
//
// Started once from BCDLiveFrontEnd's appearance: someone signed in to GeForce NOW gets the catalog
// refreshed at launch (OpenNOW does that when it starts signed in); for anyone else nothing starts.
//
// Phase 3: the search is one MCDCloudService.Request (request(for:)), the same one Cloud plays with.

import Combine
import MCDCloud
import SwiftUI

@MainActor final class MCDCloudCardsLive {
    static let shared = MCDCloudCardsLive()
    private var watching: AnyCancellable?

    private init() {}

    func start() {
        guard watching == nil else { return }
        let service = MCDCloudService.shared
        let cards = MCDCloudCards.shared
        cards.lookup = { game in Self.state(for: game, in: service) }
        cards.link = { store in service.link(store: store) }
        // The catalog's revision, and the account itself (signing in or out changes every answer).
        watching = service.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { cards.changed() } }
        if MCDCloudService.hasSignIn { service.start() }
    }

    static func state(for game: BCDGame, in service: MCDCloudService) -> MCDCloudCardState? {
        switch request(for: game).flatMap({ service.availability($0) }) {
        case .ready?: return .ready
        case .needsLink(let store, let label)?: return .link(store: store, label: label)
        case nil: return nil
        }
    }

    /// How the catalog is searched for a game (phase 2's rules; play uses the same search, so the
    /// game a card offers is the game that starts). nil: the Windows desktop, which is not a game.
    static func request(for game: BCDGame) -> MCDCloudService.Request? {
        switch game.store {
        case .steam:
            // By app ID first; by title among GeForce NOW's Steam versions when the ID is not in the catalog.
            var appID: Int?
            if case .steam(let id)? = BCDLiveID.parse(game.id) { appID = id }
            return MCDCloudService.Request(steamAppID: appID, title: game.title, store: "STEAM")
        case .epic: return MCDCloudService.Request(steamAppID: nil, title: game.title, store: "EPIC")
        case .gog: return MCDCloudService.Request(steamAppID: nil, title: game.title, store: "GOG")
        // BCD 0.1.634's stores. By title among any store's versions: GeForce NOW has no itch.io versions, and its EA
        // versions can't be kept to by name ("EA" is a substring of "STEAM" in entry(for:)'s match).
        case .itch, .ea: return MCDCloudService.Request(steamAppID: nil, title: game.title, store: nil)
        case .local:
            return game.title == "Windows desktop" ? nil : MCDCloudService.Request(steamAppID: nil, title: game.title, store: nil)
        }
    }
}
