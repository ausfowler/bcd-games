// SPDX-License-Identifier: GPL-3.0-only
// Mobile Claw Deck (MCD), a fork of BCD (https://github.com/thebcd69/bcd-games) by ausfowler.
// Added 2026-11-02. Includes work from BCD by thebcd69.
//
// MCD's whole interface to GeForce NOW. The app imports MCDCloud and sees only this file's public
// names; everything behind them is OpenNOW's own code (../OpenNOW, MIT), unchanged but for the
// patches listed in UPSTREAM.md. Phase 1 of docs (the build plan): sign in, see the account, sign
// out. The catalog and streaming come in later phases through this same object.

import Combine
import CoreImage.CIFilterBuiltins
import Foundation
import UIKit

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

    private var store: OpenNOWStore?
    private var watching: Set<AnyCancellable> = []
    private var signInTask: Task<Void, Never>?

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
        read()
        Task { await store.bootstrap() }
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
    }
}
