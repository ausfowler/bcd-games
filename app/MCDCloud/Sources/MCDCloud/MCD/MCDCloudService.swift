// SPDX-License-Identifier: GPL-3.0-only
// Mobile Claw Deck (MCD), a fork of BCD (https://github.com/thebcd69/bcd-games) by ausfowler.
// Added 2026-11-02. Includes work from BCD by thebcd69.
//
// MCD's whole interface to GeForce NOW. The app imports MCDCloud and sees only this file's public
// names; everything behind them is OpenNOW's own code (../OpenNOW, MIT), unchanged but for the
// patches listed in UPSTREAM.md. Phase 1 of the build plan: sign in, see the account, sign out.
// Phase 2: which of MCD's games GeForce NOW has (availability), and linking a store. Phase 3:
// playing one (MCDCloudStream.swift): the session's stage, the queue, the stream view.

import Combine
import CoreImage.CIFilterBuiltins
import Foundation
import UIKit

/// The catalog as MCD looks games up in it (MCDCloudService.rebuildIndex).
struct CatalogIndex {
    struct Entry {
        let gameID: String
        /// The catalog's game the version belongs to: what a launch asks GeForce NOW for.
        let game: CloudGame
        let storefront: String
        let option: GameLaunchOption
        let owned: Bool
    }
    var steam: [Int: Entry] = [:]
    var titles: [String: [Entry]] = [:]
    var connectors: [String: AccountConnector] = [:]
}

@MainActor
public final class MCDCloudService: ObservableObject {
    public static let shared = MCDCloudService()

    /// The signed-in GeForce NOW account, as OpenNOW reads it.
    public struct Account: Equatable, Sendable {
        public let name: String
        public let email: String?
        /// "Free", "Performance" or "Ultimate": OpenNOW's own reading of the tier (SmartSessionLimit).
        public let membership: String
        /// Hours left this month and the month's allowance, when the plan has one.
        public let hoursLeft: Double?
        public let hoursTotal: Double?
    }

    /// A code sign-in in progress: open `address` on any device and enter `code`.
    public struct CodeSignIn: Equatable, Sendable {
        public let code: String
        public let address: URL
        public let expires: Date
    }

    @Published public private(set) var account: Account?
    /// A sign-in is running (the NVIDIA sheet is up, or a code is waiting for approval).
    @Published public private(set) var signingIn = false
    /// OpenNOW's own words for the step a sign-in is on ("Waiting for approval").
    @Published public private(set) var step: String?
    @Published public private(set) var codeSignIn: CodeSignIn?
    /// The last sign-in failure, in OpenNOW's words; nil once a new sign-in starts.
    @Published public private(set) var error: String?

    /// Changes whenever the catalog, the GeForce NOW library or the linked stores change: what a
    /// card's Cloud button shows may have changed (availability(...) below).
    @Published public private(set) var catalogRevision = 0

    /// OpenNOW's store; module-internal, so MCDCloudStream.swift reaches it (the app cannot).
    var store: OpenNOWStore?
    private var watching: Set<AnyCancellable> = []
    private var signInTask: Task<Void, Never>?
    var index = CatalogIndex()

    // MARK: Phase 3: the session MCD started (MCDCloudStream.swift reads and writes these)

    /// What the cloud session is doing now; nil when there is none and nothing MCD asked for is pending.
    @Published public internal(set) var stage: Stage?
    /// The game the session is for (the catalog's title).
    @Published public internal(set) var sessionTitle: String?
    /// Starting this game would end another game's session: MCD asks first.
    @Published public internal(set) var conflict: Conflict?
    /// NVIDIA's queue ad is playing (the free plan): MCD's queue screen shows queueAdView().
    @Published public internal(set) var queueAd = false
    /// OpenNOW's words for a problem the session has now (a poll failed, a resume failed); nil when none.
    @Published public internal(set) var notice: String?
    /// MCD asked for the session (play) and has not let it go (leave, dismissFailure).
    var requested = false
    /// play's own launch is running (OpenNOWStore.launch, awaited).
    var launching = false
    var launchTask: Task<Void, Never>?
    /// A resume was asked for and OpenNOW has not yet started it (its reopen is a task of its own).
    var resuming = false
    var sawResumeLaunch = false
    /// MCD asked to end the session (end): its going is expected, not a failure.
    var endRequested = false
    /// OpenNOW's sessionError when end() was asked: only a new one says the end failed.
    var errorBeforeEnd: String?
    /// Why the session MCD asked for did not start, or why it ended unasked.
    var failure: String?
    var requestedTitle: String?
    /// The session the stream view is for, kept as OpenNOW's ContentView keeps it (presentedStreamerSession).
    var presented: ActiveSession?
    var streamRetries = 0
    var lastActiveID: String?
    /// The game play() would start once the conflict is confirmed.
    var pendingPlay: PendingLaunchRequest?
    /// The app's scene phase, handed to OpenNOW (observeScenePhase).
    var sceneWatching: Set<AnyCancellable> = []

    /// Set while an account is signed in, so MCD starts the engine at launch only for someone who
    /// uses the Cloud (nothing of GeForce NOW runs, and nothing is sent, until then).
    private static let signedInKey = "MCD.cloud.signedIn"
    public static var hasSignIn: Bool { UserDefaults.standard.bool(forKey: signedInKey) }

    private init() {}

    /// Starts OpenNOW's store once: it loads a saved sign-in (OpenNOW keeps it in the keychain and
    /// under its own "OpenNOW.iOS." defaults keys) and refreshes the account. Safe to call again.
    public func start() {
        guard store == nil else { return }
        let store = OpenNOWStore()
        self.store = store
        // objectWillChange fires before a value changes: read on the next turn of the main queue.
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.read() } }
            .store(in: &watching)
        // The catalog, the library and the linked stores, each as OpenNOW publishes it (it refreshes
        // all three after a sign-in and at start when signed in); the index is rebuilt once they settle.
        Publishers.CombineLatest3(store.$allGames, store.$libraryGames, store.$accountConnectors)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] all, library, connectors in
                MainActor.assumeIsolated { self?.rebuildIndex(all: all, library: library, connectors: connectors) }
            }
            .store(in: &watching)
        observeScenePhase(of: store)
        read()
        Task { await store.bootstrap() }
    }

    // MARK: Which games play with Cloud

    /// What a game's Cloud button does: play (`ready`), or first link the store GeForce NOW needs.
    public enum Availability: Equatable, Sendable {
        case ready
        /// GeForce NOW has the game for this store, it is not in the GeForce NOW library, and that
        /// store is not linked to the account: `label` is NVIDIA's name for the store ("Steam").
        case needsLink(store: String, label: String)
    }

    /// The game GeForce NOW has under this Steam app ID (read from each catalog entry's Steam store
    /// address, store.steampowered.com/app/<id>). nil: not on GeForce NOW, or signed out.
    public func availability(steamAppID: Int) -> Availability? {
        guard account != nil, let entry = index.steam[steamAppID] else { return nil }
        return availability(of: entry)
    }

    /// One of MCD's games as the catalog is searched for it: by Steam app ID first when it has one,
    /// then by title among `store`'s versions ("STEAM", "EPIC", "GOG"; nil for any).
    public struct Request: Equatable, Sendable {
        public let steamAppID: Int?
        public let title: String
        public let store: String?
        public init(steamAppID: Int?, title: String, store: String?) {
            self.steamAppID = steamAppID
            self.title = title
            self.store = store
        }
    }

    /// The Cloud button's state for a game; nil when GeForce NOW does not have it or no one is signed in.
    public func availability(_ request: Request) -> Availability? {
        entry(for: request).map { availability(of: $0) }
    }

    /// The catalog version a request finds (the same search as availability: phase 2's matching).
    func entry(for request: Request) -> CatalogIndex.Entry? {
        guard account != nil else { return nil }
        if let id = request.steamAppID, let entry = index.steam[id] { return entry }
        var entries = index.titles[Self.titleKey(request.title)] ?? []
        if let store = request.store {
            let wanted = normalizeGameStore(store)
            entries = entries.filter { normalizeGameStore($0.storefront).contains(wanted) }
        }
        return entries.first(where: \.owned) ?? entries.first
    }

    /// A game by its title, for games without a Steam app ID (added from Files, Epic, GOG). Titles
    /// match exactly once letters and digits are kept and the case is dropped ("Overcooked! All You
    /// Can Eat" = "overcookedallyoucaneat"); nothing looser. `store` keeps the match to that store's
    /// versions ("EPIC", "GOG", "STEAM"), nil for any.
    public func availability(title: String, store: String?) -> Availability? {
        availability(Request(steamAppID: nil, title: title, store: store))
    }

    /// Links a store to the GeForce NOW account: NVIDIA's page for it opens in Safari, as in OpenNOW;
    /// the linked stores are read again a few times over the next minute.
    public func link(store key: String) {
        guard let store,
              let connector = store.accountConnectors.first(where: { normalizeGameStore($0.store) == normalizeGameStore(key) })
        else { return }
        Task {
            await store.connectAccountConnector(connector) { url in
                UIApplication.shared.open(url)
            }
        }
    }

    private func availability(of entry: CatalogIndex.Entry) -> Availability {
        if entry.owned { return .ready }
        if let connector = index.connectors[normalizeGameStore(entry.storefront)], connector.supported, !connector.isLinked {
            return .needsLink(store: connector.store, label: connector.label)
        }
        return .ready
    }

    static func titleKey(_ title: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in title.lowercased().unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            kept.append(scalar)
        }
        return String(kept)
    }

    /// A Steam app ID from a Steam store address (https://store.steampowered.com/app/892970/Valheim/).
    static func steamAppID(_ address: String?) -> Int? {
        guard let address, let url = URL(string: address), let host = url.host?.lowercased(),
              host == "steampowered.com" || host.hasSuffix(".steampowered.com") else { return nil }
        let parts = url.pathComponents
        guard let at = parts.firstIndex(of: "app"), at + 1 < parts.count, let id = Int(parts[at + 1]), id > 0 else { return nil }
        return id
    }

    private func rebuildIndex(all: [CloudGame], library: [CloudGame], connectors: [AccountConnector]) {
        var next = CatalogIndex()
        // A version is in the library when either list says so (OpenNOW merges them the same way).
        let owned = Set((library + all).flatMap(\.launchOptions).filter(\.isOwned).map(\.id))
        for game in library + all {
            for option in game.launchOptions {
                let entry = CatalogIndex.Entry(gameID: game.id, game: game, storefront: option.storefront, option: option,
                                               owned: owned.contains(option.id))
                if normalizeGameStore(option.storefront) == "STEAM", let id = Self.steamAppID(option.storeURL) {
                    // Several catalog entries can name one Steam game (editions): the one in the library wins.
                    if let kept = next.steam[id], kept.owned || !entry.owned { continue }
                    next.steam[id] = entry
                }
                let key = Self.titleKey(game.title)
                guard !key.isEmpty else { continue }
                var list = next.titles[key] ?? []
                if !list.contains(where: { $0.option.id == option.id }) { list.append(entry) }
                next.titles[key] = list
            }
        }
        for connector in connectors {
            next.connectors[normalizeGameStore(connector.store)] = connector
        }
        index = next
        catalogRevision &+= 1
    }

    /// NVIDIA's sign-in page in Apple's secure sign-in sheet.
    public func signIn() {
        start()
        guard let store, !store.isAuthenticating else { return }
        signInTask?.cancel()
        signInTask = Task { await store.signIn() }
    }

    /// A code to enter on another device (a phone or computer): the way to sign in with a controller.
    public func signInWithCode() {
        start()
        guard let store, !store.isAuthenticating else { return }
        signInTask?.cancel()
        signInTask = Task { await store.signInWithCode() }
    }

    /// Stops a sign-in in progress (as OpenNOW's own Cancel does: its task is cancelled).
    public func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
    }

    public func signOut() {
        cancelSignIn()
        store?.signOut()
        read()
    }

    /// A QR code of `address`, for scanning with another device.
    public static func qrImage(for address: URL) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(address.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: image)
    }

    private func read() {
        guard let store else { return }
        let next = store.user.map { user -> Account in
            let subscription = store.subscription
            let tier = subscription?.membershipTier.isEmpty == false ? subscription?.membershipTier : user.membershipTier
            let limited = subscription.map { !$0.isUnlimited && $0.totalHours > 0 } ?? false
            let name = user.displayName.isEmpty ? (user.email ?? "GeForce NOW") : user.displayName
            return Account(name: name, email: user.email,
                           membership: SmartSessionLimit.forTier(tier).tierLabel,
                           hoursLeft: limited ? subscription?.remainingHours : nil,
                           hoursTotal: limited ? subscription?.totalHours : nil)
        }
        if next != account { account = next }
        if store.isAuthenticating != signingIn { signingIn = store.isAuthenticating }
        if store.authenticationPhase != step { step = store.authenticationPhase }
        let code = store.deviceLoginPrompt.map { CodeSignIn(code: $0.userCode, address: $0.verificationURL, expires: $0.expiresAt) }
        if code != codeSignIn { codeSignIn = code }
        if store.authError != error { error = store.authError }
        if Self.hasSignIn != (next != nil) { UserDefaults.standard.set(next != nil, forKey: Self.signedInKey) }
        readSession()
    }
}
