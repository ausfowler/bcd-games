// SPDX-License-Identifier: GPL-3.0-only
// Mobile Claw Deck (MCD), a fork of BCD (https://github.com/thebcd69/bcd-games) by ausfowler.
// Added 2026-11-02. Includes work from BCD by thebcd69.
//
// MCDCloudPlay on the engine (phase 3): Cloud's screen reads MCD Cloud's session
// (MCDCloudService.stage and the rest) and its buttons ask MCD Cloud. Engine-bound
// (tools/ui-preview.py, ENGINE_BOUND).
//
// The controllers, the keyboard and the mice. Each of their buttons holds one handler at a time.
// Outside a stream MCD's own input code holds them: the controller hub (BCDControllerHub: its
// tester and key mapping), the XInput reader (GamepadInput) and the keyboard and mouse reader
// (HardwareInput). The stream's input (OpenNOW) sets its own when it starts and sets them to nil
// when it stops. Left alone, MCD's would be gone after a stream, and a controller connecting
// during one could put MCD's handlers back under the stream's, on another queue. So OpenNOW says
// when (MCDCloudInput, posted synchronously on the main thread: UPSTREAM.md), and here MCD steps
// aside just before it takes them and takes them back just after it lets go.

import Combine
import GameController
import MCDCloud
import SwiftUI
import UIKit

@MainActor final class MCDCloudPlayLive {
    static let shared = MCDCloudPlayLive()
    private var watching: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    /// MCD's input code has stepped aside for a stream.
    private var held = false
    /// The hub was on when it stepped aside (it is turned back on only then).
    private var hubWasOn = false
    private var orphanCheck: DispatchWorkItem?

    private init() {}

    /// Once, from BCDLiveFrontEnd's appearance (beside MCDCloudCardsLive.start()). Nothing of GeForce
    /// NOW starts here: the service starts when someone signed in launches the app or presses Cloud.
    func start() {
        guard watching == nil else { return }
        let service = MCDCloudService.shared
        let play = MCDCloudPlay.shared
        play.start = { game in
            guard let request = MCDCloudCardsLive.request(for: game) else { return }
            service.start()
            service.play(request)
            Self.sync()
        }
        play.resume = { service.resume(); Self.sync() }
        play.end = { service.end(); Self.sync() }
        play.leave = { service.leave(); Self.sync() }
        play.confirm = { service.confirmConflict(); Self.sync() }
        play.cancel = { service.cancelConflict(); Self.sync() }
        play.streamView = { service.streamView() }
        play.adView = { service.queueAdView() }
        watching = service.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { Self.sync() } }

        // A nil queue: the block runs at once, on the posting thread (OpenNOW posts both on the main
        // thread), before the stream sets its handlers / after it has cleared them.
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: MCDCloudInput.willAttach, object: nil, queue: nil) { _ in
            Self.onMain { MCDCloudPlayLive.shared.stepAside() }
        })
        observers.append(center.addObserver(forName: MCDCloudInput.didDetach, object: nil, queue: nil) { _ in
            Self.onMain {
                // The stream has just cleared every handler it set. Normally MCD stepped aside for it; if
                // MCD already took its input back (orphanedHold), that input lost its handlers just now,
                // so it steps aside and takes them back again: the same steps, in the same order.
                let live = MCDCloudPlayLive.shared
                if !live.held { live.stepAside() }
                live.takeBack()
            }
        })
    }

    /// MCD Cloud's session, as Cloud's screen shows it.
    static func sync() {
        let service = MCDCloudService.shared
        let stage: MCDCloudStage? = service.stage.map { (stage: MCDCloudService.Stage) -> MCDCloudStage in
            switch stage {
            case .starting: return .starting
            case .waiting(let status, let position, let estimate): return .waiting(status: status, position: position, estimate: estimate)
            case .streaming: return .streaming
            case .paused: return .paused
            case .ending: return .ending
            case .failed(let message): return .failed(message)
            }
        }
        MCDCloudPlay.shared.apply(stage: stage, title: service.sessionTitle,
                                  conflict: service.conflict.map { MCDCloudConflict(running: $0.running, requested: $0.requested) },
                                  queueAd: service.queueAd, notice: service.notice)
        shared.orphanedHold()
    }

    /// OpenNOW lets go of the input when the stream's view goes (its coordinator stops on the view's
    /// disappearance). A view that goes while the app is not active is kept for Picture in Picture
    /// instead, and its input may never say it let go: MCD's would stay aside. So two seconds after
    /// the session stopped streaming (long after the view went), with the app active and still no
    /// word, MCD takes its input back itself.
    private func orphanedHold() {
        guard held, MCDCloudService.shared.stage != .streaming else {
            orphanCheck?.cancel()
            orphanCheck = nil
            return
        }
        guard orphanCheck == nil else { return }
        let check = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.orphanCheck = nil
                guard self.held, MCDCloudService.shared.stage != .streaming,
                      UIApplication.shared.applicationState == .active else { return }
                LogStore.shared.log("[cloud] the stream's view went without letting go of the input: MCD takes it back")
                self.takeBack()
            }
        }
        orphanCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: check)
    }

    /// The stream is about to take the controllers, keyboard and mice.
    private func stepAside() {
        guard !held else { return }
        held = true
        let hub = BCDControllerHub.shared
        hubWasOn = hub.isOn
        if hubWasOn { hub.setOn(false) }        // its handlers go now, synchronously
        GamepadInput.shared.setCloudHold(true)  // XInput: attaches nothing new meanwhile
        HardwareInput.shared.setCloudHold(true) // keyboard and mice: let go, on the main queue
        LogStore.shared.log("[cloud] stream started: MCD's controller, keyboard and mouse input stepped aside")
    }

    /// The stream has let go of them.
    private func takeBack() {
        guard held else { return }
        held = false
        orphanCheck?.cancel()
        orphanCheck = nil
        GamepadInput.shared.setCloudHold(false)
        HardwareInput.shared.setCloudHold(false)
        if hubWasOn { BCDControllerHub.shared.setOn(true) }
        LogStore.shared.log("[cloud] stream ended: MCD's controller, keyboard and mouse input back")
    }

    /// At once on the main thread (where OpenNOW posts); otherwise as soon as the main thread can.
    nonisolated private static func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            Task { @MainActor in work() }
        }
    }
}
