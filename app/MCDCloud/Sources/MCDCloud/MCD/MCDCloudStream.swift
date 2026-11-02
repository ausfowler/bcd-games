// SPDX-License-Identifier: GPL-3.0-only
// Mobile Claw Deck (MCD), a fork of BCD (https://github.com/thebcd69/bcd-games) by ausfowler.
// Added 2026-11-02. Includes work from BCD by thebcd69.
//
// Phase 3 of the build plan: playing a game in the cloud. Everything that runs the session is
// OpenNOW's (OpenNOWStore.launch, its queue polling, StreamerView); this file asks it, reads where
// the session stands in MCD's words (Stage), and hands MCD the stream view built exactly as
// OpenNOW's own ContentView builds it (streamerSurface), with the same callbacks.

import Combine
import Foundation
import SwiftUI
import UIKit

/// The stream's input code (OpenNOW's NativeStreamInputBridge, patched: UPSTREAM.md) says when it
/// takes the controllers', keyboard's and mouse's handlers and when it has let them go. A button
/// holds one handler at a time, so MCD's own input code steps aside in between. Both are posted on
/// the main thread, synchronously: an observer added with a nil queue runs before the stream goes on.
public enum MCDCloudInput {
    /// Just before the stream sets the handlers.
    public static let willAttach = Notification.Name("MCDCloud.inputWillAttach")
    /// Just after it has set them back to nil.
    public static let didDetach = Notification.Name("MCDCloud.inputDidDetach")
}

extension MCDCloudService {
    /// Where the cloud session stands.
    public enum Stage: Equatable, Sendable {
        /// MCD asked GeForce NOW for a rig and has no answer yet.
        case starting
        /// In line or being set up: OpenNOW's words for it, the place in line, and its estimate of the
        /// wait from how the line has moved ("About 4 min"), when it has one.
        case waiting(status: String, position: Int?, estimate: String?)
        /// The stream is on screen (streamView()).
        case streaming
        /// The session runs on GeForce NOW with no stream on screen: resume or end it.
        case paused
        /// Ending it.
        case ending
        /// The session MCD asked for did not start, or ended unasked: why.
        case failed(String)
    }

    /// Starting a game while another game's session holds the rig.
    public struct Conflict: Equatable, Sendable {
        public let running: String
        public let requested: String
    }

    // MARK: Asking

    /// Plays a game GeForce NOW has (availability says .ready). The same game's session, if one runs,
    /// is resumed instead; another game's asks first (conflict).
    public func play(_ request: Request) {
        guard let store, let entry = entry(for: request) else { return }
        requested = true
        requestedTitle = entry.game.title
        failure = nil
        endRequested = false
        // OpenNOW's launch refuses this too, but says it only where its own screens look (lastError).
        if let restriction = store.launchRestrictionMessage(for: entry.game) {
            failure = restriction
            readSession()
            return
        }
        if let active = store.activeSession, active.game.id == entry.game.id {
            resume()
            return
        }
        // OpenNOW's own rule (LaunchConflict.between): another game's session that holds a rig would be ended.
        let pending = PendingLaunchRequest(game: entry.game, zoneUrl: nil, launchOption: entry.option)
        if let conflict = store.launchConflict(for: pending) {
            pendingPlay = pending
            self.conflict = Conflict(running: conflict.runningGame.title, requested: entry.game.title)
            readSession()
            return
        }
        launch(pending, endingFirst: false)
    }

    /// Ends the other game's session, then starts the asked one (as OpenNOW's confirmPendingLaunch,
    /// but awaited here, so the screen stays on "Starting" in between and a failure is caught).
    public func confirmConflict() {
        guard let pending = pendingPlay else { return }
        pendingPlay = nil
        conflict = nil
        launch(pending, endingFirst: true)
    }

    /// Keeps the other game's session; nothing starts.
    public func cancelConflict() {
        pendingPlay = nil
        conflict = nil
        requested = false
        readSession()
    }

    /// Back to the running session: its stream if the rig is ready, else its queue.
    public func resume() {
        guard let store, store.activeSession != nil else { return }
        requested = true
        resuming = true
        sawResumeLaunch = false
        store.jumpBackToSession()
        readSession()
    }

    /// Ends the session on GeForce NOW (in line, the place in line goes).
    public func end() {
        guard let store else { return }
        endRequested = true
        errorBeforeEnd = store.sessionError
        pendingPlay = nil
        conflict = nil
        launchTask?.cancel()
        launchTask = nil
        launching = false
        Task { await store.endSession() }
        readSession()
    }

    /// MCD's screen closed: MCD no longer waits on the session (a running one keeps running).
    public func leave() {
        requested = false
        failure = nil
        pendingPlay = nil
        conflict = nil
        readSession()
    }

    private func launch(_ request: PendingLaunchRequest, endingFirst: Bool) {
        guard let store else { return }
        launching = true
        launchTask?.cancel()
        // OpenNOW clears sessionError when a launch starts, not lastError: only a new lastError is this launch's.
        let lastErrorBefore = store.lastError
        launchTask = Task { [weak self] in
            if endingFirst {
                await store.endSession(cancelPendingLaunch: false)
                guard !Task.isCancelled else { return }
            } else {
                // Phase 4 (folding: option A, nothing ever restarts). A session this game already has on GeForce NOW
                // (started on the other screen, on another device, before the app was closed) is resumed as it runs:
                // OpenNOW's launch would end it and start another when its mode differs from the one asked for here.
                await store.refreshRemoteSessions()
                guard !Task.isCancelled else { return }
                let appID = request.launchOption?.appId ?? request.game.launchAppId
                if let appID, let running = store.resumableSessions.first(where: { $0.appId == appID && (1...3).contains($0.status) }) {
                    self?.mode = nil
                    await store.resumeSession(candidate: running)
                    guard let self, !Task.isCancelled else { return }
                    self.launching = false
                    if store.activeSession == nil, self.requested, !self.endRequested {
                        self.failure = Self.words(store.sessionError)
                            ?? (store.lastError != lastErrorBefore ? Self.words(store.lastError) : nil)
                            ?? "GeForce NOW couldn't resume the session that's running. Try again in a moment."
                    }
                    self.readSession()
                    return
                }
            }
            // The mode for the screen in use now (MCDStreamFit); kept for the whole session.
            let screen = self?.screenSettings(store)
            self?.mode = screen.map { "\($0.preferredResolution.replacingOccurrences(of: "x", with: " × ")) · \($0.preferredFPS) fps" }
            await store.launch(game: request.game, launchOption: request.launchOption, settingsOverride: screen)
            guard let self, !Task.isCancelled else { return }
            self.launching = false
            // A launch that returns with no session failed; OpenNOW put why in sessionError (most
            // failures) or lastError (a refused zone); returning at once means another change was running.
            if store.activeSession == nil, self.requested, !self.endRequested {
                self.failure = Self.words(store.sessionError)
                    ?? (store.lastError != lastErrorBefore ? Self.words(store.lastError) : nil)
                    ?? "GeForce NOW is busy with another change to your session. Try again in a moment."
            }
            self.readSession()
        }
        readSession()
    }

    /// OpenNOW's settings with the mode for the screen the app is on (MCDStreamFit) and the shape Settings › Cloud
    /// chose (phase 4b), for a new session; nil
    /// keeps OpenNOW's own (no scene to measure, or a resolution someone chose that is not Auto).
    func screenSettings(_ store: OpenNOWStore) -> AppSettings? {
        var settings = store.settings
        guard settings.preferredResolution == "Auto" else { return nil }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return nil }
        let points = scene.coordinateSpace.bounds.size
        let scale = scene.screen.nativeScale
        let tier = store.subscription?.membershipTier ?? store.user?.membershipTier
        let fit = MCDStreamFit.choose(pixels: CGSize(width: points.width * scale, height: points.height * scale),
                                      plan: StreamSettingsResolver.plan(for: tier),
                                      maxFPS: scene.screen.maximumFramesPerSecond,
                                      shape: UserDefaults.standard.string(forKey: MCDStreamFit.shapeKey))
        settings.preferredAspectRatio = fit.aspectRatio
        settings.preferredResolution = fit.resolution
        settings.preferredFPS = fit.fps
        return settings
    }

    // MARK: Reading

    /// Called whenever OpenNOW's store changed (read(), on the next turn of the main queue).
    func readSession() {
        guard let store else { return }
        // The stream view's session, kept exactly as OpenNOW's ContentView keeps presentedStreamerSession:
        // a new stream session replaces it; it goes when no session is left, or when the stream closes
        // (onClose and onRetry below clear it themselves).
        if let stream = store.streamSession {
            if presented?.id != stream.id { presented = stream }
        } else if store.activeSession == nil {
            presented = nil
        }
        let activeID = store.activeSession?.id
        if activeID != lastActiveID {
            // ContentView: a new (or no) session starts with fresh retries.
            streamRetries = 0
            // The session MCD was waiting on went away and nobody here ended it: GeForce NOW ended it.
            if lastActiveID != nil, activeID == nil, requested, !endRequested, !launching, failure == nil {
                failure = Self.words(store.sessionError) ?? "GeForce NOW ended the session."
            }
            lastActiveID = activeID
        }
        if resuming {
            if store.isLaunchingSession { sawResumeLaunch = true }
            if presented != nil || store.showStreamLoading || store.activeSession == nil
                || (sawResumeLaunch && !store.isLaunchingSession) {
                resuming = false
            }
        }
        if endRequested, !store.isEndingSession, store.activeSession == nil {
            // Ended. If GeForce NOW could not stop it, OpenNOW says so (a new sessionError): that stays on screen.
            endRequested = false
            if store.sessionError != errorBeforeEnd, let message = Self.words(store.sessionError) {
                failure = message
            } else {
                requested = false
            }
        }

        let next: Stage?
        if store.isEndingSession {
            next = .ending
        } else if presented != nil {
            next = .streaming
        } else if let active = store.activeSession {
            if store.showStreamLoading {
                next = Self.waiting(store, active)
            } else if launching || resuming || store.isLaunchingSession {
                next = .waiting(status: "Connecting", position: nil, estimate: nil)
            } else {
                next = .paused
            }
        } else if launching || store.isLaunchingSession {
            next = .starting
        } else if requested, let failure {
            next = .failed(failure)
        } else if requested, pendingPlay != nil {
            next = .starting
        } else {
            next = nil
        }
        if next != stage { stage = next }

        // While a launch replaces another game's session, the screen names the game coming.
        let title = (launching || pendingPlay != nil) ? requestedTitle : (store.activeSession?.game.title ?? (requested ? requestedTitle : nil))
        if title != sessionTitle { sessionTitle = title }
        let ad: Bool = {
            guard let active = store.activeSession, store.activeQueueAd != nil else { return false }
            return !QueueSessionPhase.isPastQueue(active)
        }()
        if ad != queueAd { queueAd = ad }
        let problem: String? = {
            switch next {
            case .waiting?, .paused?, .starting?: return Self.words(store.sessionError)
            default: return nil
            }
        }()
        if problem != notice { notice = problem }
    }

    /// In line or being set up, in OpenNOW's words (its queue screen's queueStatusText).
    private static func waiting(_ store: OpenNOWStore, _ active: ActiveSession) -> Stage {
        if QueueSessionPhase.isPastQueue(active) {
            return .waiting(status: active.status == 1 ? "Setting up your rig" : "Connecting to the stream", position: nil, estimate: nil)
        }
        if let position = store.displayQueuePosition, position > 0 {
            return .waiting(status: "In line", position: position, estimate: store.queueTrend.supportLine(now: Date()))
        }
        if let ads = store.effectiveAdState, ads.opportunity?.queuePaused == true || ads.isQueuePaused == true {
            return .waiting(status: "Line paused", position: nil, estimate: nil)
        }
        if active.seatSetupStep == 1 {
            return .waiting(status: "Waiting for a rig", position: nil, estimate: nil)
        }
        return .waiting(status: store.isLaunchingSession ? "Starting" : "In line", position: nil, estimate: nil)
    }

    private static func words(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    // MARK: Views

    /// The stream, while there is one: OpenNOW's StreamerView in its full-screen presentation,
    /// built as OpenNOW's ContentView builds it (streamerSurface). Up to three automatic retries.
    public func streamView() -> AnyView? {
        guard let store, let session = presented else { return nil }
        return AnyView(
            NativeStreamPresentation {
                StreamerView(
                    session: session,
                    settings: store.currentStreamerSettings,
                    sessionHistory: store.sessionHistory,
                    membershipTier: store.subscription?.membershipTier ?? store.user?.membershipTier,
                    onTouchLayoutChange: { profile, layout in store.updateTouchControlLayout(layout, profile: profile) },
                    onStreamerPreferencesChange: { store.updateStreamerPreferences($0) },
                    onStreamSharpeningChange: { enabled, amount in store.updateStreamSharpening(enabled: enabled, amount: amount) },
                    onFingerMouseEnabledChange: { store.updateFingerMouseEnabled($0) },
                    onPhoneRumbleFallbackChange: { store.updatePhoneRumbleFallback($0) },
                    onStreamTutorialCompleted: { store.setStreamTutorialCompleted(true) },
                    onControllerTouchPromptDismissed: { store.setControllerTouchPromptDismissed(true) },
                    onStatsOverlayChange: { store.updateStreamStatsOverlayVisible($0) },
                    onTransportStable: { [weak self] in self?.streamRetries = 0 },
                    onSelectedVideoProfileRetry: { store.recordStreamRecovery(reason: $0) },
                    onNativeFallbackRequiresFreshEndpoint: { _ in },
                    onRuntimeSample: { store.recordStreamRuntimeSample($0) },
                    onSettingsChange: { store.applyStreamerSettings($0) },
                    onBuildBugReportDeck: { store.bugReportPreflightDeck() },
                    onSubmitBugReport: { draft, deck in await store.submitBugReport(draft, deck: deck) },
                    onClose: { [weak self] in
                        // Exit in the stream's controls: the session keeps running (paused).
                        self?.presented = nil
                        self?.streamRetries = 0
                        store.dismissStreamer()
                        self?.readSession()
                    },
                    onRetry: streamRetries < 3 ? { [weak self] in
                        self?.presented = nil
                        self?.streamRetries += 1
                        self?.resuming = true
                        self?.sawResumeLaunch = false
                        store.dismissStreamer()
                        store.scheduleStreamerReopen()
                        self?.readSession()
                    } : nil
                )
                .ignoresSafeArea()
                .environmentObject(store)
                .openNowTheme(store.settings)
            }
            .ignoresSafeArea()
            .id(session.id)
        )
    }

    /// NVIDIA's queue ad (GeForce NOW's free plan), OpenNOW's player, while one plays.
    public func queueAdView() -> AnyView? {
        guard let store, queueAd, let ad = store.activeQueueAd else { return nil }
        return AnyView(
            QueueAdPlayerCard(ad: ad, compact: true)
                .environmentObject(store)
                .openNowTheme(store.settings)
                .environment(\.colorScheme, .dark)
        )
    }

    // MARK: The app's state, for OpenNOW

    /// OpenNOW's own app hands its store the scene's phase (OpenNOWiOSApp); MCD's scene is MCD's, so
    /// the same four moments come from UIKit's notifications instead. Called once, from start().
    func observeScenePhase(of store: OpenNOWStore) {
        // WebRTC's settings must be in place before anything of WebRTC starts (OpenNOW's app delegate).
        NativeStreamWebRTCPolicy.initialize()
        let center = NotificationCenter.default
        let phases: [(Notification.Name, ScenePhase)] = [
            (UIApplication.didBecomeActiveNotification, .active),
            (UIApplication.willResignActiveNotification, .inactive),
            (UIApplication.didEnterBackgroundNotification, .background),
            (UIApplication.willEnterForegroundNotification, .inactive),
        ]
        for (name, phase) in phases {
            center.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak store] _ in MainActor.assumeIsolated { store?.handleScenePhase(phase) } }
                .store(in: &sceneWatching)
        }
        store.handleScenePhase(UIApplication.shared.applicationState == .active ? .active : .inactive)
    }
}
