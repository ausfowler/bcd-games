// SPDX-License-Identifier: GPL-3.0-only
// Mobile Claw Deck (MCD), a fork of BCD (https://github.com/thebcd69/bcd-games) by ausfowler.
// Added 2026-11-02. Includes work from BCD by thebcd69.
//
// Settings › Cloud: the GeForce NOW account MCD streams with. Sign in with NVIDIA's page (Apple's
// secure sign-in sheet) or with a code entered on another device (the way with a controller), see
// the account and its membership, sign out. Plain values and views, as Settings' other pages: the
// engine side is MCDCloudLive.swift (tools/ui-preview.py's ENGINE_BOUND keeps it out of the
// preview app, which shows this section's placeholder).

import SwiftUI

/// The signed-in GeForce NOW account.
struct MCDCloudAccount: Equatable {
    var name: String
    var email: String?
    /// "Free", "Performance" or "Ultimate".
    var membership: String
    /// This month's hours left and allowance, for a plan that has one.
    var hoursLeft: Double?
    var hoursTotal: Double?
}

/// A sign-in in progress.
struct MCDCloudSignIn: Equatable {
    var busy = false
    /// The step it is on, in the engine's words ("Waiting for approval").
    var step: String?
    /// A code sign-in: the code, where to enter it, and that address as a QR code.
    var code: String?
    var address: URL?
    var qr: UIImage?
    var error: String?
}

@MainActor protocol MCDCloudBackend: ObservableObject {
    var account: MCDCloudAccount? { get }
    var signIn: MCDCloudSignIn { get }
    /// NVIDIA's sign-in page, in the system's secure sign-in sheet.
    func signInWithBrowser()
    /// A code to enter on a phone or computer.
    func signInWithCode()
    func cancelSignIn()
    func signOut()
}

struct MCDCloudSection<Backend: MCDCloudBackend>: View {
    @ObservedObject var backend: Backend
    var backHook: BCDSectionKit.BackHook? = nil
    @EnvironmentObject private var focus: BCDFocus
    @State private var confirmingSignOut = false

    private static var prefix: String { "settings.cloud." }

    var body: some View {
        BCDSectionKit.Page(title: "Cloud", subtitle: "GeForce NOW, for the games you choose to play with Cloud.",
                           focusPrefix: Self.prefix) {
            BCDSectionKit.Columns {
                accountCard
            } right: {
                aboutCard
            }
        }
        .modifier(BCDSectionKit.Buttons(focus: focus,
                                        key: "\(backend.account != nil)-\(confirmingSignOut)-\(backend.signIn.code != nil)",
                                        inner: closeInner, hook: backHook))
        .onChange(of: backend.account) { _, account in
            if account == nil { confirmingSignOut = false }
            if focus.controllerActive { focus.focused = Self.prefix + (account == nil ? "signin" : "signout") }
        }
        .onChange(of: backend.signIn.code) { _, code in
            // A code appeared: the ring goes to Cancel. It went away without an account (cancelled,
            // expired): back to Sign in. With an account, the account's change above places the ring.
            guard focus.controllerActive else { return }
            if code != nil { focus.focused = Self.prefix + "cancel" }
            else if backend.account == nil { focus.focused = Self.prefix + "signin" }
        }
    }

    /// B inside the page: the sign-out question closes, then a code sign-in stops. False: nothing was open.
    private func closeInner() -> Bool {
        if confirmingSignOut {
            confirmingSignOut = false
            if focus.controllerActive { focus.focused = Self.prefix + "signout" }
            return true
        }
        if backend.signIn.code != nil {
            backend.cancelSignIn()
            return true
        }
        return false
    }

    // MARK: The account

    private var accountCard: some View {
        BCDSectionKit.Card(eyebrow: "GeForce NOW", symbol: "cloud.fill", accent: backend.account == nil) {
            if let account = backend.account {
                signedIn(account)
            } else if backend.signIn.code != nil {
                codeSignIn
            } else {
                signedOut
            }
            if let error = backend.signIn.error, backend.account == nil {
                BCDSectionKit.Note(text: error, symbol: "exclamationmark.triangle.fill", tone: .bad)
            }
        }
    }

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 14) {
            BCDSectionKit.Headline(text: "Not signed in", symbol: "cloud", tone: .soft,
                                   detail: "Sign in with the NVIDIA account you use for GeForce NOW.")
            if backend.signIn.busy {
                BCDSectionKit.Note(text: backend.signIn.step ?? "Signing in…", symbol: "hourglass", tone: .info)
            }
            BCDSectionKit.ActionButton(title: "Sign in with NVIDIA", symbol: "person.crop.circle.badge.plus", kind: .primary,
                                       fill: true, id: Self.prefix + "signin", enabled: !backend.signIn.busy) {
                backend.signInWithBrowser()
            }
            BCDSectionKit.ActionButton(title: "Sign in with a code", symbol: "qrcode", kind: .outline, fill: true,
                                       id: Self.prefix + "signin.code", enabled: !backend.signIn.busy) {
                backend.signInWithCode()
            }
            Text("With a code, you sign in on another phone or a computer: the way to do it with a controller.")
                .bcdFont(.body, 13).foregroundStyle(BCDStyle.textSoft).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var codeSignIn: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Finish signing in on another device").bcdFont(.heading, 18).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 16) {
                if let qr = backend.signIn.qr {
                    Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                        .frame(width: 132, height: 132)
                        .padding(8)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityLabel("QR code for NVIDIA's sign-in page")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Scan the code, or open").bcdFont(.body, 14).foregroundStyle(BCDStyle.textSoft)
                    if let address = backend.signIn.address {
                        // The whole address but its "https://": its path is part of what to type.
                        Text(Self.typed(address)).bcdFont(.label, 15).textSelection(.enabled)
                            .lineLimit(2).minimumScaleFactor(0.7).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("and enter").bcdFont(.body, 14).foregroundStyle(BCDStyle.textSoft)
                    Text(backend.signIn.code ?? "").font(.system(size: 26, weight: .bold, design: .monospaced)).tracking(2)
                        .textSelection(.enabled).lineLimit(1).minimumScaleFactor(0.6)
                }
            }
            BCDSectionKit.Note(text: backend.signIn.step ?? "Waiting for approval", symbol: "hourglass", tone: .info)
            BCDSectionKit.ActionButton(title: "Cancel", symbol: "xmark", kind: .outline, fill: true, id: Self.prefix + "cancel") {
                backend.cancelSignIn()
            }
        }
    }

    private func signedIn(_ account: MCDCloudAccount) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(BCDStyle.glow)
                    Text(String(account.name.first ?? "G").uppercased())
                        .font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                }
                .frame(width: 54, height: 54)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.name).bcdFont(.heading, 19).lineLimit(1).minimumScaleFactor(0.8)
                    if let email = account.email, email != account.name {
                        Text(email).bcdFont(.body, 14).foregroundStyle(BCDStyle.textSoft).lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                Spacer(minLength: 8)
                BCDStatusChip(text: "Signed in", color: BCDStyle.mint)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 22) {
                fact("Membership", account.membership)
                if let left = account.hoursLeft, let total = account.hoursTotal {
                    fact("This month", "\(Self.hours(left)) of \(Self.hours(total)) left")
                }
            }
            if confirmingSignOut {
                BCDSectionKit.Confirm(
                    title: "Sign out of GeForce NOW?",
                    message: "MCD removes your NVIDIA sign-in from this \(BCDSectionKit.deviceWord). Your games and their saves on this \(BCDSectionKit.deviceWord) stay. To play with Cloud again, sign in again.",
                    choices: [
                        .init(title: "Sign out", kind: .danger, id: Self.prefix + "signout.confirm") {
                            confirmingSignOut = false
                            backend.signOut()
                        },
                        .init(title: "Cancel", kind: .outline, id: Self.prefix + "signout.cancel") {
                            confirmingSignOut = false
                            if focus.controllerActive { focus.focused = Self.prefix + "signout" }
                        },
                    ])
            } else {
                BCDSectionKit.ActionButton(title: "Sign out", symbol: "rectangle.portrait.and.arrow.right", kind: .danger,
                                           id: Self.prefix + "signout") {
                    confirmingSignOut = true
                    if focus.controllerActive { focus.focused = Self.prefix + "signout.cancel" }
                }
            }
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).bcdFont(.body, 13).foregroundStyle(BCDStyle.textSoft)
            Text(value).bcdFont(.label, 16).lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    /// An address as someone types it: without "https://" (or "http://") and a trailing "/".
    static func typed(_ address: URL) -> String {
        var text = address.absoluteString
        for scheme in ["https://", "http://"] where text.lowercased().hasPrefix(scheme) {
            text.removeFirst(scheme.count)
        }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// "12 h" or "12.5 h" (plain arithmetic, no formatter).
    static func hours(_ value: Double) -> String {
        guard value.isFinite else { return "–" }
        let tenths = (value * 10).rounded()
        return tenths.truncatingRemainder(dividingBy: 10) == 0 ? "\(Int(tenths / 10)) h" : "\(Int(tenths) / 10).\(abs(Int(tenths)) % 10) h"
    }

    // MARK: About

    private var aboutCard: some View {
        BCDSectionKit.Card(eyebrow: "How it works", symbol: "info.circle") {
            VStack(alignment: .leading, spacing: 10) {
                Text("A game played with Cloud runs on NVIDIA's servers and streams to this \(BCDSectionKit.deviceWord), so it does not need to be installed here.")
                    .bcdFont(.body, 14).fixedSize(horizontal: false, vertical: true)
                BCDSectionKit.Note(text: "Games GeForce NOW has get a Cloud button on their card on Home. Streaming them comes next.",
                                   symbol: "sparkles", tone: .info)
                BCDSectionKit.Note(text: "MCD streams with OpenNOW, an open-source GeForce NOW client. NVIDIA does not make or endorse it.",
                                   symbol: "exclamationmark.shield", tone: .soft)
            }
        }
    }
}
