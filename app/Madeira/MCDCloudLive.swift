// SPDX-License-Identifier: GPL-3.0-only
// Mobile Claw Deck (MCD), a fork of BCD (https://github.com/thebcd69/bcd-games) by ausfowler.
// Added 2026-11-02. Includes work from BCD by thebcd69.
//
// Settings › Cloud on the engine: MCDCloudSettings.swift's page, fed by MCD Cloud's service
// (app/MCDCloud, OpenNOW's engine). Engine-bound: tools/ui-preview.py's ENGINE_BOUND keeps it out
// of the preview app. Opening the page starts the service (MCDCloudService.start(), once per run):
// nothing of GeForce NOW runs before someone opens Cloud.

import Combine
import MCDCloud
import SwiftUI

@MainActor final class MCDCloudLive: MCDCloudBackend {
    @Published private(set) var account: MCDCloudAccount?
    @Published private(set) var signIn = MCDCloudSignIn()
    private var watching: Set<AnyCancellable> = []
    /// The QR code of the last code sign-in's address, made once per address.
    private var qr: (address: URL, image: UIImage?)?

    init() {
        let service = MCDCloudService.shared
        service.start()
        // objectWillChange fires before the value changes: read on the next turn of the main queue.
        service.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.read() } }
            .store(in: &watching)
        read()
    }

    private func read() {
        let service = MCDCloudService.shared
        let next = service.account.map {
            MCDCloudAccount(name: $0.name, email: $0.email, membership: $0.membership,
                            hoursLeft: $0.hoursLeft, hoursTotal: $0.hoursTotal)
        }
        if next != account { account = next }
        let code = service.codeSignIn
        if let address = code?.address, qr?.address != address {
            qr = (address, MCDCloudService.qrImage(for: address))
        }
        let progress = MCDCloudSignIn(busy: service.signingIn, step: service.step, code: code?.code, address: code?.address,
                                      qr: code == nil ? nil : qr?.image, error: service.error)
        if progress != signIn { signIn = progress }
    }

    func signInWithBrowser() { MCDCloudService.shared.signIn() }
    func signInWithCode() { MCDCloudService.shared.signInWithCode() }
    func cancelSignIn() { MCDCloudService.shared.cancelSignIn() }
    func signOut() { MCDCloudService.shared.signOut() }
}

/// Settings › Cloud, as BCDSettingsLive.swift's custom page (B asks the page first: BCDSettingsSectionBack).
struct MCDCloudLiveSection: View {
    var backHook: BCDSectionKit.BackHook? = nil
    @StateObject private var backend = MCDCloudLive()

    var body: some View {
        MCDCloudSection(backend: backend, backHook: backHook)
    }
}
