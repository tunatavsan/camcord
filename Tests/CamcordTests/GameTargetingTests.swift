import AppKit
import Foundation
import Testing

@testable import Camcord

/// The rules that decide what the window picker offers and what the record
/// hotkey does when a fullscreen game owns the screen. All pure — no ScreenCaptureKit.
@MainActor
@Suite("Game targeting")
struct GameTargetingTests {

    private let display = CGRect(x: 0, y: 0, width: 1512, height: 982)

    private func candidate(
        bundleID: String? = "com.example.app",
        appName: String = "Example",
        title: String = "Doc",
        frame: CGRect = CGRect(x: 0, y: 0, width: 400, height: 300),
        isOnScreen: Bool = true,
        policy: NSApplication.ActivationPolicy? = .regular
    ) -> PickerCandidate {
        PickerCandidate(
            bundleID: bundleID, appName: appName, title: title,
            frame: frame, isOnScreen: isOnScreen, activationPolicy: policy
        )
    }

    private func rejection(_ candidate: PickerCandidate) -> PickerRejection? {
        WindowPickerPanel.rejection(for: candidate, ownBundleID: "dev.tavsan.camcord", displayFrames: [display])
    }

    @Test("an ordinary on-screen window of a regular app is eligible")
    func regularWindowPasses() {
        #expect(rejection(candidate()) == nil)
    }

    @Test("own windows, tiny windows and windows without a running app are rejected by name")
    func baselineRejections() {
        #expect(rejection(candidate(bundleID: "dev.tavsan.camcord")) == .ownApp)
        #expect(rejection(candidate(frame: CGRect(x: 0, y: 0, width: 79, height: 300))) == .tooSmall)
        #expect(rejection(candidate(policy: nil)) == .noApplication)
        #expect(rejection(candidate(policy: .prohibited)) == .activationPolicy)
    }

    @Test("an accessory app is eligible only while its window covers a display")
    func accessoryNeedsToCoverADisplay() {
        // The Valheim case: a fullscreen game with no Dock tile used to fall out here.
        #expect(rejection(candidate(frame: display, policy: .accessory)) == nil)
        #expect(rejection(candidate(policy: .accessory)) == .activationPolicy)
        // The double-scaled frame a fullscreen-exclusive app reports still covers.
        let doubled = CGRect(x: 0, y: 0, width: display.width * 2, height: display.height * 2)
        #expect(rejection(candidate(frame: doubled, policy: .accessory)) == nil)
    }

    @Test("an off-screen window passes only when it is display-sized")
    func offScreenNeedsToBeDisplaySized() {
        #expect(rejection(candidate(isOnScreen: false)) == .offScreen)
        #expect(rejection(candidate(frame: display, isOnScreen: false)) == nil)
    }

    @Test("the rejection line names the app, frame, on-screen state, policy and rule")
    func diagnosticsLineExplainsTheRejection() {
        let line = WindowPickerPanel.diagnosticsLine(
            candidate(bundleID: "com.valve.valheim", appName: "Valheim", title: "",
                      frame: CGRect(x: 0, y: 0, width: 3024, height: 1964),
                      isOnScreen: false, policy: .accessory),
            .activationPolicy
        )
        #expect(line.contains("rule=not-regular-app"))
        #expect(line.contains("app=Valheim"))
        #expect(line.contains("bundle=com.valve.valheim"))
        #expect(line.contains("title=-"))
        #expect(line.contains("frame=0,0 3024x1964"))
        #expect(line.contains("onScreen=false"))
        #expect(line.contains("policy=accessory"))
    }

    @Test("the fullscreen card appears only when no eligible window of that app covers the display")
    func fullscreenCardFillsTheGap() {
        let covering = [(bundleID: String?.some("com.game"), frame: display)]
        let small = [(bundleID: String?.some("com.game"), frame: CGRect(x: 0, y: 0, width: 400, height: 300))]
        #expect(!WindowPickerPanel.needsFullscreenCard(bundleID: "com.game", eligible: covering, displayFrame: display))
        #expect(WindowPickerPanel.needsFullscreenCard(bundleID: "com.game", eligible: small, displayFrame: display))
        #expect(WindowPickerPanel.needsFullscreenCard(bundleID: "com.game", eligible: [], displayFrame: display))
        // Another app's fullscreen window does not stand in for the game's.
        let other = [(bundleID: String?.some("com.other"), frame: display)]
        #expect(WindowPickerPanel.needsFullscreenCard(bundleID: "com.game", eligible: other, displayFrame: display))
    }

    @Test("the record hotkey records the display only when a game is up and nothing is running")
    func recordHotkeyRouting() {
        #expect(HotkeyCenter.recordAction(isBusy: false, isGameLike: true) == .gameDisplay)
        // The same hotkey must stop the run it started, and never start a second one.
        #expect(HotkeyCenter.recordAction(isBusy: true, isGameLike: true) == .toggle)
        #expect(HotkeyCenter.recordAction(isBusy: false, isGameLike: false) == .toggle)
        #expect(HotkeyCenter.recordAction(isBusy: true, isGameLike: false) == .toggle)
    }

    @Test("the covering window is read past our own windows, the desktop and transparent panels")
    func firstCoveringSkipsOurOwnChrome() {
        let bounds = CGRect(x: 0, y: 0, width: 1512, height: 982)
        func entry(pid: pid_t, owner: String, frame: CGRect, alpha: Double = 1, layer: Int = 0) -> [String: Any] {
            [
                kCGWindowOwnerPID as String: pid,
                kCGWindowOwnerName as String: owner,
                kCGWindowAlpha as String: alpha,
                kCGWindowLayer as String: layer,
                kCGWindowBounds as String: frame.dictionaryRepresentation as NSDictionary,
            ]
        }
        // Front to back: our own panel, a transparent overlay, the desktop, then the game.
        let list = [
            entry(pid: 1, owner: "Camcord", frame: bounds, layer: 25),
            entry(pid: 2, owner: "Other", frame: bounds, alpha: 0),
            entry(pid: 3, owner: "Finder", frame: bounds),
            entry(pid: 4, owner: "Notes", frame: CGRect(x: 0, y: 0, width: 400, height: 300)),
            entry(pid: 5, owner: "Valheim", frame: bounds, layer: 8),
        ]
        let covering = FullscreenContext.firstCovering(in: list, excludingPID: 1, displayBounds: bounds)
        #expect(covering?.pid == 5)
        #expect(covering?.layer == 8)
        #expect(FullscreenContext.firstCovering(in: [], excludingPID: 1, displayBounds: bounds) == nil)
    }

    @Test("a covering window makes the context game-like unless it is our own app")
    func gameLikeContext() {
        func context(front: String?, covers: Bool) -> FullscreenContext {
            FullscreenContext(displayID: 1, frontmostBundleID: front, coversDisplay: covers,
                              windowLayer: 0, displayCaptured: false)
        }
        #expect(context(front: "com.game", covers: true).isGameLike)
        #expect(!context(front: "com.game", covers: false).isGameLike)
        #expect(!context(front: Bundle.main.bundleIdentifier, covers: true).isGameLike)
        #expect(!context(front: nil, covers: true).isGameLike)
    }

    @Test("a game drawing from another process than the app in front still covers the display")
    func coverFallsBackToTheWindowList() {
        // The Valheim run: eight triggers reported `covers=false layer=0`, because the app in
        // front (the launcher, pid 7) owns no window at all and the game's window belongs to
        // pid 9. The frontmost-PID read alone can never see that window.
        let list = [
            windowEntry(pid: 1, owner: "Camcord", frame: display, layer: 25),
            windowEntry(pid: 9, owner: "Valheim", frame: display, layer: 8),
        ]
        let fallback = FullscreenContext.cover(in: list, frontmostPID: 7, ownPID: 1, displayBounds: display)
        #expect(fallback?.layer == 8)
        #expect(fallback?.pid == 9)
        #expect(fallback?.source == "list")
        // The frontmost app's own covering window still answers first.
        let front = FullscreenContext.cover(in: list, frontmostPID: 9, ownPID: 1, displayBounds: display)
        #expect(front?.source == "front")
        // A full-display wallpaper below every ordinary window is not a game, and our own
        // covering panel is never the answer either.
        let wallpaper = [windowEntry(pid: 4, owner: "Wallpaper", frame: display, layer: -2)]
        #expect(FullscreenContext.cover(in: wallpaper, frontmostPID: 7, ownPID: 1, displayBounds: display) == nil)
        #expect(FullscreenContext.cover(in: [list[0]], frontmostPID: 7, ownPID: 1, displayBounds: display) == nil)
    }

    @Test("system chrome that covers the display is never mistaken for a game")
    func systemChromeIsNotCover() {
        // Measured on this machine: the Dock owns a full-display window at level 20, the
        // Window Server one at 24 and Control Center a row at 25. Reading any of them as
        // cover would have declared a fullscreen game every time the app in front owned no
        // full-display window — which is most of the time.
        for (owner, layer) in [("Dock", 20), ("Window Server", 24), ("Control Center", 25),
                               ("Wispr Flow", 1000), ("Notification Center", -2147483601)] {
            let chrome = [windowEntry(pid: 42, owner: owner, frame: display, layer: layer)]
            #expect(
                FullscreenContext.cover(in: chrome, frontmostPID: 7, ownPID: 1, displayBounds: display) == nil,
                "\(owner) at level \(layer) must not read as cover"
            )
            // The app IN FRONT is trusted at any level: it is what the user is looking at.
            #expect(FullscreenContext.cover(in: chrome, frontmostPID: 42, ownPID: 1, displayBounds: display)?
                .source == "front")
        }
        #expect(FullscreenContext.ordinaryLayers == 0..<20)
    }

    @Test("a fullscreen window reported in backing pixels covers a display off the origin")
    func pixelScaledBoundsStillCover() {
        // A fullscreen-exclusive app can report window bounds in backing PIXELS while
        // `CGDisplayBounds` is in points. On the second display the origin is scaled too, so
        // the raw rectangle misses the containment test entirely.
        let second = CGRect(x: 1512, y: 0, width: 1512, height: 982)
        let pixels = CGRect(x: 3024, y: 0, width: 3024, height: 1964)
        #expect(FullscreenContext.coveringLayer(
            in: [windowEntry(pid: 9, owner: "Valheim", frame: pixels, layer: 8)],
            pid: 9, displayBounds: second
        ) == 8)
        // Scaling can only ever shrink a window, so nothing smaller than the display passes.
        #expect(FullscreenContext.coveringLayer(
            in: [windowEntry(pid: 9, owner: "Valheim", frame: CGRect(x: 1512, y: 0, width: 800, height: 600))],
            pid: 9, displayBounds: second
        ) == nil)
    }

    @Test("the trigger line carries the display and each candidate's geometry, layer and alpha")
    func surveyExplainsTheMeasurement() {
        let list = [windowEntry(pid: 9, owner: "Valheim", frame: CGRect(x: 0, y: 0, width: 3024, height: 1964), layer: 8)]
        let context = FullscreenContext(
            displayID: 1, frontmostBundleID: "com.valve.valheim", coversDisplay: true,
            windowLayer: 8, displayCaptured: false,
            survey: FullscreenContext.survey(in: list, pid: 9, displayBounds: display, source: "list")
        )
        let line = context.logLine
        #expect(line.contains("covers=true"))
        #expect(line.contains("game=true"))
        #expect(line.contains("cover=list"))
        // The display and the window in ONE space at the SAME scale: 1512x982 against
        // 3024x1964 is the points-vs-pixels mismatch, visible instead of guessed.
        #expect(line.contains("bounds=0,0 1512x982"))
        #expect(line.contains("win=0,0 3024x1964"))
        #expect(line.contains("front=1/1"))
        #expect(line.contains("Valheim/9 layer=8 alpha=1.00"))
        // A trigger with no windows at all still produces one line, with no candidates.
        #expect(FullscreenContext.survey(in: [], pid: nil, displayBounds: display, source: "none")
            .contains("front=0/0 []"))
    }

    private func windowEntry(
        pid: pid_t, owner: String, frame: CGRect, alpha: Double = 1, layer: Int = 0
    ) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: pid,
            kCGWindowOwnerName as String: owner,
            kCGWindowAlpha as String: alpha,
            kCGWindowLayer as String: layer,
            kCGWindowBounds as String: frame.dictionaryRepresentation as NSDictionary,
        ]
    }
}
