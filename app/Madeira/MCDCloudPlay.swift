// SPDX-License-Identifier: GPL-3.0-only
// Mobile Claw Deck (MCD), a fork of BCD (https://github.com/thebcd69/bcd-games) by ausfowler.
// Added 2026-11-02. Includes work from BCD by thebcd69.
//
// Playing a game in the cloud (phase 3 of the build plan): MCD's screen over the shell from the
// moment Cloud is pressed until the session is left. It says where the session stands (starting,
// in line, setting up the rig, paused, ending, failed) over the game's art, with the buttons that
// apply; the stream itself is OpenNOW's, shown over everything while it runs.
//
// Plain values and SwiftUI only: MCDCloudPlayLive.swift (engine-bound) fills `MCDCloudPlay` from
// MCD Cloud and answers its actions; in the preview app nothing installs them and nothing opens it.

import SwiftUI

/// Where a cloud session stands (MCDCloudService.Stage, the same cases).
enum MCDCloudStage: Equatable {
    case starting
    case waiting(status: String, position: Int?, estimate: String?)
    case streaming
    case paused
    case ending
    case failed(String)
}

/// Starting the game would end another game's session.
struct MCDCloudConflict: Equatable {
    let running: String
    let requested: String
}

@MainActor final class MCDCloudPlay: ObservableObject {
    static let shared = MCDCloudPlay()

    /// The screen is up.
    @Published private(set) var open = false
    /// The game whose card opened it: the screen's art.
    @Published private(set) var game: BCDGame?
    @Published private(set) var stage: MCDCloudStage?
    /// The cloud session's game (GeForce NOW's title for it).
    @Published private(set) var title: String?
    @Published private(set) var conflict: MCDCloudConflict?
    /// NVIDIA's queue ad is playing (GeForce NOW's free plan): `adView` shows it.
    @Published private(set) var queueAd = false
    /// A problem the session has now, in OpenNOW's words.
    @Published private(set) var notice: String?

    // The live side (MCDCloudPlayLive.swift); nothing happens until it is installed.
    var start: (BCDGame) -> Void = { _ in }
    var resume: () -> Void = {}
    var end: () -> Void = {}
    var leave: () -> Void = {}
    var confirm: () -> Void = {}
    var cancel: () -> Void = {}
    var streamView: () -> AnyView? = { nil }
    var adView: () -> AnyView? = { nil }

    private init() {}

    /// Cloud on a game's card.
    func play(_ game: BCDGame) {
        self.game = game
        open = true
        start(game)
    }

    /// B on a paused session or a failure: back to Home (a running session keeps running).
    func close() {
        open = false
        leave()
    }

    /// The live side's reading of the session. The screen closes when nothing is left to show; a
    /// stream that starts (a resume) opens it, so Exit lands on it.
    func apply(stage: MCDCloudStage?, title: String?, conflict: MCDCloudConflict?, queueAd: Bool, notice: String?) {
        if stage != self.stage { self.stage = stage }
        if title != self.title { self.title = title }
        if conflict != self.conflict { self.conflict = conflict }
        if queueAd != self.queueAd { self.queueAd = queueAd }
        if notice != self.notice { self.notice = notice }
        if stage == .streaming, !open { open = true }
        if stage == nil, conflict == nil, open { open = false }
    }
}

// MARK: - The shell draws it

/// The cloud screen over the shell. It holds the controller while it is up (the layer "cloud."):
/// its buttons replace the screen's, and closing it gives back Home's buttons and ring. While the
/// stream runs, the interface reads no controller at all (the stream has it).
struct MCDCloudHost: ViewModifier {
    @ObservedObject var model: MCDCloudPlay
    @EnvironmentObject private var focus: BCDFocus
    static let layer = "cloud."

    func body(content: Content) -> some View {
        content
            .overlay {
                if model.open {
                    MCDCloudScreen(model: model, buttons: buttons)
                        .ignoresSafeArea()
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: model.open)
            .onChange(of: model.open) { _, open in
                if open { focus.openLayer(Self.layer) } else { focus.closeLayer(Self.layer) }
                install()
            }
            .onChange(of: model.stage) { _, _ in install() }
            .onChange(of: model.conflict) { _, _ in install() }
            .onChange(of: model.stage == .streaming) { _, streaming in focus.enabled = !streaming }
            .onDisappear {
                guard model.open else { return }
                focus.closeLayer(Self.layer)
            }
    }

    /// What the buttons do now, in the order the screen shows them.
    private var buttons: [MCDCloudButton] {
        if let conflict = model.conflict {
            return [MCDCloudButton(button: .a, title: "End and play", action: model.confirm),
                    // Keeping the other game's session is a no to this one: back to Home.
                    MCDCloudButton(button: .b, title: "Keep \(conflict.running)", action: { model.cancel(); model.close() })]
        }
        switch model.stage {
        case .waiting(_, .some, _)?:   // a place in line
            return [MCDCloudButton(button: .b, title: "Leave queue", action: model.end)]
        case .starting?, .waiting?:
            return [MCDCloudButton(button: .b, title: "Cancel", action: model.end)]
        case .paused?:
            return [MCDCloudButton(button: .a, title: "Resume", action: model.resume),
                    MCDCloudButton(button: .x, title: "End session", action: model.end),
                    MCDCloudButton(button: .b, title: "Home", action: { model.close() })]
        case .failed?:
            return [MCDCloudButton(button: .b, title: "Close", action: { model.close() })]
        case .streaming?, .ending?, nil:
            return []
        }
    }

    private func install() {
        guard model.open else { return }
        focus.setHandlers(buttons.map { (BCDHint(button: $0.button, title: $0.title), $0.action) })
    }
}

struct MCDCloudButton: Identifiable {
    var id: BCDButton { button }
    let button: BCDButton
    let title: String
    let action: () -> Void
}

/// The screen itself: the game's art, a glass card with where the session stands, its buttons.
struct MCDCloudScreen: View {
    @ObservedObject var model: MCDCloudPlay
    let buttons: [MCDCloudButton]

    var body: some View {
        ZStack {
            if model.stage == .streaming {
                // The stream presents itself over everything; under it, nothing to draw.
                Color.black
                model.streamView()
            } else {
                MCDBackdrop(game: model.game)
                Color.black.opacity(0.35)
                card.padding(24)
            }
        }
    }

    private var card: some View {
        VStack(spacing: 18) {
            Label("CLOUD", systemImage: "cloud.fill")
                .font(BCDStyle.label(13)).tracking(1.6)
                .foregroundStyle(BCDStyle.fuchsia)
            Text(model.title ?? model.game?.title ?? "GeForce NOW")
                .font(BCDStyle.title(28))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            status
            if let notice = model.notice {
                Text(notice)
                    .font(BCDStyle.body(14))
                    .foregroundStyle(BCDStyle.alert)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !buttons.isEmpty {
                HStack(spacing: 12) {
                    ForEach(buttons) { item in
                        Button(action: item.action) {
                            BCDHintView(hint: BCDHint(button: item.button, title: item.title))
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(Color.white.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
        }
        .foregroundStyle(BCDStyle.text)
        .padding(.horizontal, 32).padding(.vertical, 28)
        .frame(maxWidth: 560)
        .bcdGlass(cornerRadius: 24)
    }

    @ViewBuilder private var status: some View {
        if let conflict = model.conflict {
            line("End your \(conflict.running) session?",
                 "\(conflict.requested) needs the rig \(conflict.running) is using. Unsaved progress in \(conflict.running) will be lost.")
        } else {
            switch model.stage {
            case .starting?:
                progress("Asking GeForce NOW for a rig")
            case .waiting(let status, let position, let estimate)?:
                if model.queueAd, let ad = model.adView() {
                    ad.frame(maxWidth: 480)
                    Text(position.map { "\(status) · \($0) ahead of you" } ?? status)
                        .font(BCDStyle.body(15)).foregroundStyle(BCDStyle.textSoft)
                } else if let position {
                    VStack(spacing: 4) {
                        Text("\(position)").font(.system(size: 56, weight: .bold)).monospacedDigit()
                        Text(position == 1 ? "You're next" : "ahead of you in line")
                            .font(BCDStyle.body(16)).foregroundStyle(BCDStyle.textSoft)
                        if let estimate {
                            Text(estimate).font(BCDStyle.body(14)).foregroundStyle(BCDStyle.textSoft).monospacedDigit()
                        }
                    }
                } else {
                    progress(status)
                }
            case .paused?:
                line("Still running on GeForce NOW",
                     "Your GeForce NOW time keeps counting until you end the session.")
            case .ending?:
                progress("Ending the session")
            case .failed(let message)?:
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28)).foregroundStyle(BCDStyle.alert)
                    Text(message).font(BCDStyle.body(16)).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .streaming?, nil:
                EmptyView()
            }
        }
    }

    private func progress(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large).tint(BCDStyle.text)
            Text(text).font(BCDStyle.body(16)).foregroundStyle(BCDStyle.textSoft)
        }
    }

    private func line(_ heading: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Text(heading).font(BCDStyle.heading(18))
            Text(detail).font(BCDStyle.body(15)).foregroundStyle(BCDStyle.textSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
