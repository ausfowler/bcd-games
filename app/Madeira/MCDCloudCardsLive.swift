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
        let found: MCDCloudService.Availability?
        switch game.store {
        case .steam:
            if case .steam(let appID)? = BCDLiveID.parse(game.id) {
                found = service.availability(steamAppID: appID) ?? service.availability(title: game.title, store: "STEAM")
            } else {
                found = service.availability(title: game.title, store: "STEAM")
            }
        case .epic: found = service.availability(title: game.title, store: "EPIC")
        case .gog: found = service.availability(title: game.title, store: "GOG")
        case .local:
            // The Windows desktop is not a game.
            found = game.title == "Windows desktop" ? nil : service.availability(title: game.title, store: nil)
        }
        switch found {
        case .ready?: return .ready
        case .needsLink(let store, let label)?: return .link(store: store, label: label)
        case nil: return nil
        }
    }
}
