import AppKit
import Testing

@testable import Camcord

@Suite("Camera interaction", .serialized)
struct CameraInteractionTests {
    let area = CGSize(width: 1800, height: 1100)

    @Test("free dragging trails gently, then catches up when released")
    func pointerFollowing() {
        let frame = CGRect(x: 500, y: 350, width: 396, height: 222.75)
        var motion = CameraDragMotion(frame: frame, area: area)
        for tick in 1...60 {
            motion.follow(CGPoint(x: 500 + Double(tick) * 5, y: 350))
            motion.step(seconds: 1.0 / 120)
        }
        // The follow spring trails by ~16 ms, half of what it used to.
        let lag = 800 - motion.frame.minX
        #expect(lag > 4 && lag < 10)
        #expect(motion.magnetCorner == nil)
        // Releasing throws it: the rightward flick docks bottom-right, not where it stopped.
        motion.follow(CGPoint(x: 800, y: 350), released: true)
        for _ in 0..<90 { motion.step(seconds: 1.0 / 120) }
        #expect(motion.isSettled)
        #expect(motion.magnetCorner == .bottomRight)
        let dock = CameraOptions(corner: .bottomRight).rect(in: area)
        #expect(hypot(motion.frame.minX - dock.minX, motion.frame.minY - dock.minY) < 0.1)
    }

    @Test("a release docks to the corner its throw was heading for")
    func releaseFlingProjection() {
        let size = CGSize(width: 396, height: 222.75)
        let centre = CGPoint(x: (area.width - size.width) / 2, y: (area.height - size.height) / 2)
        let flicks: [(CGPoint, CameraCorner)] = [
            (CGPoint(x: 2_000, y: -1_200), .bottomRight),
            (CGPoint(x: -2_000, y: -1_200), .bottomLeft),
            (CGPoint(x: 2_000, y: 1_200), .topRight),
            (CGPoint(x: -2_000, y: 1_200), .topLeft),
        ]
        for (velocity, expected) in flicks {
            var motion = CameraDragMotion(frame: CGRect(origin: centre, size: size),
                                          area: area, velocity: velocity)
            motion.follow(centre, released: true)
            #expect(motion.magnetCorner == expected)
        }
        // A fast flick left docks left even though the frame is still on the right.
        let right = CameraOptions(corner: .bottomRight).rect(in: area)
        var thrown = CameraDragMotion(frame: right, area: area, velocity: CGPoint(x: -3_000, y: 0))
        thrown.follow(right.origin, released: true)
        #expect(thrown.magnetCorner == .bottomLeft)
    }

    @Test("the released dock seats within 450 ms without overshooting the corner")
    func releasedDockSettles() {
        let size = CGSize(width: 396, height: 222.75)
        let centre = CGPoint(x: (area.width - size.width) / 2, y: (area.height - size.height) / 2)
        var motion = CameraDragMotion(frame: CGRect(origin: centre, size: size),
                                      area: area, velocity: CGPoint(x: 2_000, y: -1_200))
        motion.follow(centre, released: true)
        let target = motion.target
        let distance = hypot(target.x - centre.x, target.y - centre.y)
        var elapsed = 0.0
        var overshoot = 0.0
        while elapsed < 0.45, !motion.isSettled {
            motion.step(seconds: 1.0 / 120)
            elapsed += 1.0 / 120
            let beyond = (motion.frame.minX - target.x) * (target.x - centre.x)
                + (motion.frame.minY - target.y) * (target.y - centre.y)
            overshoot = max(overshoot, beyond / distance)
        }
        #expect(motion.isSettled)
        #expect(elapsed < 0.45)
        #expect(overshoot <= distance * 0.04)
    }

    @Test("Reduce Motion seats the release in one pass, with no animated steps left")
    func reduceMotionFinishesImmediately() {
        let size = CGSize(width: 396, height: 222.75)
        let centre = CGPoint(x: (area.width - size.width) / 2, y: (area.height - size.height) / 2)
        var motion = CameraDragMotion(frame: CGRect(origin: centre, size: size),
                                      area: area, velocity: CGPoint(x: 2_000, y: -1_200))
        motion.follow(centre, released: true)
        motion.finishImmediately()
        let seated = motion.frame
        #expect(motion.isSettled)
        #expect(seated.origin == motion.target)
        motion.step(seconds: 1.0 / 120)
        #expect(motion.frame == seated)
    }

    @Test("dock stretches, breaks away without a jump, attracts again and seats on release")
    func magneticDrag() throws {
        for corner in CameraCorner.allCases {
            let rest = CameraOptions(corner: corner).rect(in: area)
            let unit = CameraPosition(corner: corner)
            let sx: CGFloat = unit.x == 0 ? 1 : -1
            let sy: CGFloat = unit.y == 0 ? 1 : -1
            var motion = CameraDragMotion(frame: rest, area: area)
            #expect(motion.magnetCorner == corner)
            let near = CGPoint(x: rest.minX + sx * 60, y: rest.minY + sy * 40)
            motion.follow(near)
            for _ in 0..<60 { motion.step(seconds: 1.0 / 120) }
            let stretch = hypot(motion.frame.minX - rest.minX, motion.frame.minY - rest.minY)
            #expect(stretch > 8 && stretch < 25)
            let previous = motion.frame
            let velocity = motion.velocity
            let far = CGPoint(x: rest.minX + sx * 150, y: rest.minY + sy * 120)
            motion.follow(far)
            #expect(motion.magnetCorner == nil)
            #expect(motion.frame == previous)
            #expect(motion.velocity == velocity)
            motion.step(seconds: 1.0 / 120)
            // Catching up to the pointer is fast but never a teleport.
            let reach = hypot(far.x - previous.minX, far.y - previous.minY)
            #expect(hypot(motion.frame.minX - previous.minX, motion.frame.minY - previous.minY) < reach * 0.5)
            for _ in 0..<90 { motion.step(seconds: 1.0 / 120) }
            #expect(hypot(motion.frame.minX - far.x, motion.frame.minY - far.y) < 0.1)
            motion.follow(near)
            #expect(motion.magnetCorner == corner)
            motion.follow(near, released: true)
            for _ in 0..<90 { motion.step(seconds: 1.0 / 120) }
            #expect(motion.isSettled)
            #expect(hypot(motion.frame.minX - rest.minX, motion.frame.minY - rest.minY) < 0.1)
        }
    }

    @Test("motion remains stable across 60/120 Hz and a stalled frame")
    func displayCadence() {
        let frame = CGRect(x: 500, y: 350, width: 396, height: 222.75)
        var slow = CameraDragMotion(frame: frame, area: area)
        var fast = slow
        let destination = CGPoint(x: 740, y: 490)
        slow.follow(destination)
        fast.follow(destination)
        for _ in 0..<12 { slow.step(seconds: 1.0 / 60) }
        for _ in 0..<24 { fast.step(seconds: 1.0 / 120) }
        #expect(hypot(slow.frame.minX - fast.frame.minX, slow.frame.minY - fast.frame.minY) < 0.1)
        fast.follow(CGPoint(x: -1000, y: -1000))
        fast.step(seconds: 10)
        #expect(fast.frame.minX.isFinite && fast.frame.minY.isFinite)
        #expect(fast.frame.minX >= CameraOptions.margin(in: area))
    }

    @Test("resizing latches onto the common sizes and stays free between them")
    func resizeWidthSnaps() {
        for stop in CameraResizeGeometry.widthStops {
            #expect(CameraResizeGeometry.snappedWidthFraction(stop + 0.014) == stop)
            #expect(CameraResizeGeometry.snappedWidthFraction(stop - 0.014) == stop)
        }
        // 0.28 sits outside every window (0.25 and 0.33 are both further than 0.015).
        #expect(CameraResizeGeometry.snappedWidthFraction(0.28) == 0.28)

        var options = CameraOptions(widthFraction: 0.22)
        options.place(CGRect(x: 600, y: 400, width: 396, height: 222.75), in: area)
        let start = options.rect(in: area)
        // Grow by just under one snap window's worth past 0.25 (450 pt of 1800).
        let pull = 450 - start.width + area.width * 0.010
        let snapped = CameraResizeGeometry.resize(start: start, translation: CGPoint(x: pull, y: pull / CameraOptions.aspectRatio),
                                                  corner: .topRight, options: options, in: area)
        #expect(snapped.widthFraction == 0.25)
        let free = CameraResizeGeometry.resize(start: start, translation: CGPoint(x: pull + area.width * 0.020,
                                                                                 y: (pull + area.width * 0.020) / CameraOptions.aspectRatio),
                                               corner: .topRight, options: options, in: area)
        #expect(abs(free.widthFraction - 0.28) < 0.001)
    }

    @Test("each corner resizes continuously with a fixed opposite corner and aspect ratio")
    func proportionalResize() {
        var options = CameraOptions(widthFraction: 0.22)
        options.place(CGRect(x: 600, y: 400, width: 396, height: 222.75), in: area)
        let start = options.rect(in: area)
        for corner in CameraCorner.allCases {
            let unit = CameraPosition(corner: corner)
            let sx: CGFloat = unit.x == 0 ? -1 : 1
            let sy: CGFloat = unit.y == 0 ? -1 : 1
            let grown = CameraResizeGeometry.resize(start: start,
                translation: CGPoint(x: sx * 160, y: sy * 90), corner: corner, options: options, in: area).rect(in: area)
            #expect(abs(grown.width - start.width - 160) < 0.01)
            #expect(abs(grown.width / grown.height - 16.0 / 9.0) < 0.001)
            #expect(abs((unit.x == 1 ? grown.minX - start.minX : grown.maxX - start.maxX)) < 0.01)
            #expect(abs((unit.y == 1 ? grown.minY - start.minY : grown.maxY - start.maxY)) < 0.01)
            // Opposing x/y movement used to flip the dominant axis and jump size.
            let a = CameraResizeGeometry.resize(start: start, translation: CGPoint(x: sx * 80, y: sy * -44.9),
                                                corner: corner, options: options, in: area).rect(in: area)
            let b = CameraResizeGeometry.resize(start: start, translation: CGPoint(x: sx * 80, y: sy * -45.1),
                                                corner: corner, options: options, in: area).rect(in: area)
            #expect(abs(a.width - b.width) < 0.2)
        }
    }

    @Test("even the docked outer corner can grow and shrink across the full size range")
    func dockedResize() {
        for corner in CameraCorner.allCases {
            let options = CameraOptions(corner: corner)
            let start = options.rect(in: area)
            let unit = CameraPosition(corner: corner)
            let sx: CGFloat = unit.x == 0 ? -1 : 1
            let sy: CGFloat = unit.y == 0 ? -1 : 1
            let large = CameraResizeGeometry.resize(start: start, translation: CGPoint(x: sx * 1600, y: sy * 900),
                                                    corner: corner, options: options, in: area).rect(in: area)
            let small = CameraResizeGeometry.resize(start: start, translation: CGPoint(x: sx * -1600, y: sy * -900),
                                                    corner: corner, options: options, in: area).rect(in: area)
            #expect(abs(large.width - 1080) < 0.01)
            #expect(abs(small.width - 144) < 0.01)
            #expect(large.minX >= 32.99 && large.minY >= 32.99)
            #expect(large.maxX <= area.width - 32.99 && large.maxY <= area.height - 32.99)
        }
    }

    @Test("corner hit areas remain distinct and include the visible handle at every size")
    func cornerTargets() {
        for width in [144.0, 396.0, 1080.0] {
            let bounds = CGRect(x: 0, y: 0, width: width, height: width * 9 / 16)
            #expect(CameraResizeGeometry.corner(at: CGPoint(x: bounds.midX, y: bounds.midY), in: bounds) == nil)
            for corner in CameraCorner.allCases {
                let unit = CameraPosition(corner: corner)
                let inset = max(17, CameraOptions.cornerRadius(for: bounds.size) * 0.48)
                let point = CGPoint(x: unit.x == 0 ? inset : bounds.width - inset,
                                    y: unit.y == 0 ? inset : bounds.height - inset)
                #expect(CameraResizeGeometry.corner(at: point, in: bounds) == corner)
                #expect(CameraResizeGeometry.hitRect(corner, in: bounds).width >= 37)
            }
        }
    }

    @Test("native hover reveals only the nearby corner, and that same zone starts resizing")
    @MainActor func nativeCornerHover() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 360),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = FloatingCameraView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        window.contentView = view
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            if type == .mouseEntered || type == .mouseExited {
                return try #require(NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                         windowNumber: window.windowNumber, context: nil,
                                                         eventNumber: 0, trackingNumber: 0, userData: nil))
            }
            return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil,
                                           eventNumber: 0, clickCount: 1, pressure: 0))
        }
        view.mouseEntered(with: try event(.mouseEntered, CGPoint(x: 320, y: 180)))
        #expect(view.indicatedCorner == nil)
        view.mouseMoved(with: try event(.mouseMoved, CGPoint(x: 35, y: 35)))
        #expect(view.indicatedCorner == .bottomLeft)
        view.mouseMoved(with: try event(.mouseMoved, CGPoint(x: 605, y: 325)))
        #expect(view.indicatedCorner == .topRight)
        var beganCorner: CameraCorner?
        view.onDrag = { phase, _, corner in if phase == .began { beganCorner = corner } }
        view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 605, y: 325)))
        #expect(beganCorner == .topRight)
        view.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 605, y: 325)))
        view.mouseExited(with: try event(.mouseExited, CGPoint(x: -10, y: 325)))
        #expect(view.indicatedCorner == nil)
        window.close()
    }

    @Test("recording camera flag and panel lifecycle keep the hidden preview monitor idle")
    @MainActor func hiddenPreviewStaysClosedAcrossPanelLifecycle() {
        _ = NSApplication.shared
        let overlay = CameraOverlayController.shared
        let oldPreviewVisible = overlay.previewVisible
        let monitor = CameraPreviewMonitor.shared
        let wasStarting = monitor.isStarting
        let wasRunning = monitor.isRunning
        defer {
            overlay.previewVisible = false
            overlay.recordingEnded()
            overlay.previewVisible = oldPreviewVisible
            overlay.hide()
        }

        overlay.previewVisible = false
        overlay.hide()
        overlay.prepareRecording(
            cgRect: CGRect(x: -10_000, y: -10_000, width: 640, height: 360),
            options: CameraOptions(enabled: true)
        )
        #expect(!overlay.isVisible)
        let panel = PanelController(
            model: RecordingStateModel(),
            actions: PanelActions(),
            detachedPanelPresenter: { _, _ in true }
        )
        panel.presentDetached()
        panel.close()
        #expect(!overlay.previewVisible)
        #expect(!overlay.isVisible)
        #expect(monitor.isStarting == wasStarting)
        #expect(monitor.isRunning == wasRunning)

        overlay.previewVisible = true
        overlay.prepareRecording(
            cgRect: CGRect(x: -10_000, y: -10_000, width: 640, height: 360),
            options: CameraOptions(enabled: false)
        )
        #expect(overlay.isVisible)
        panel.presentDetached()
        panel.close()
        #expect(overlay.previewVisible)
        #expect(overlay.isVisible)
    }

    @Test("placement from every surface persists and emits the resolved options")
    @MainActor func placementSourcesShareOneFunnel() throws {
        let defaults = UserDefaults.standard
        let key = RecordingSettings.defaultsKey
        let savedData = defaults.data(forKey: key)
        let overlay = CameraOverlayController.shared
        let savedCallback = overlay.onPlacementChange
        let savedPreview = overlay.previewVisible
        defer {
            overlay.onPlacementChange = nil
            if let savedData { defaults.set(savedData, forKey: key) } else { defaults.removeObject(forKey: key) }
            overlay.previewVisible = savedPreview
            overlay.hide()
            overlay.onPlacementChange = savedCallback
        }

        var emitted: [CameraOptions] = []
        overlay.onPlacementChange = { emitted.append($0) }
        let sources: [CameraOverlayController.PlacementSource] = [.floating, .stage, .settings]
        for (index, source) in sources.enumerated() {
            let options = CameraOptions(enabled: true, deviceID: " camera-\(index) ",
                                        widthFraction: 0.18 + Double(index) * 0.1,
                                        mirrored: index.isMultiple(of: 2),
                                        position: CameraPosition(x: Double(index) / 3, y: Double(index + 1) / 4))
            overlay.applyPlacement(options, source: source)
            let expected = options.resolved()
            #expect(RecordingSettings.load(from: defaults).camera == expected)
            #expect(emitted.last == expected)
        }
        #expect(emitted.count == 3)
    }

    @Test("hidden recording preparation follows moved window bounds and remains confined")
    @MainActor func hiddenPreparationTracksMovedWindowBounds() throws {
        _ = NSApplication.shared
        let overlay = CameraOverlayController.shared
        let savedPreview = overlay.previewVisible
        defer {
            overlay.previewVisible = false
            overlay.recordingEnded()
            overlay.previewVisible = savedPreview
            overlay.hide()
        }
        overlay.previewVisible = false
        let options = CameraOptions(widthFraction: 0.6, position: CameraPosition(x: 1, y: 1))
        let initial = CGRect(x: 100, y: 120, width: 800, height: 500)
        let moved = CGRect(x: 700, y: 260, width: 420, height: 280)
        overlay.prepareRecording(cgRect: initial, options: options)
        #expect(!overlay.isVisible)
        overlay.updateRecordingBounds(cgRect: moved)
        let nativePanel = try #require(NSApp.windows.first { $0.contentView is FloatingCameraView })
        let appKitBounds = Geometry.cgToAppKit(moved,
            primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0)
        let expected = options.rect(in: appKitBounds.size)
            .offsetBy(dx: appKitBounds.minX, dy: appKitBounds.minY)
        // AppKit rounds native window origins to the screen-point grid.
        #expect(abs(nativePanel.frame.minX - expected.minX) < 1)
        #expect(abs(nativePanel.frame.minY - expected.minY) < 1)
        #expect(nativePanel.frame.maxX <= appKitBounds.maxX + 0.01)
        #expect(nativePanel.frame.maxY <= appKitBounds.maxY + 0.01)
    }

    @Test("a live drag reaches the compositor every frame but persists only when it settles")
    @MainActor func livePlacementDefersPersistence() throws {
        let defaults = UserDefaults.standard
        let key = RecordingSettings.defaultsKey
        let savedData = defaults.data(forKey: key)
        let overlay = CameraOverlayController.shared
        let savedCallback = overlay.onPlacementChange
        defer {
            overlay.onPlacementChange = nil
            if let savedData { defaults.set(savedData, forKey: key) } else { defaults.removeObject(forKey: key) }
            overlay.onPlacementChange = savedCallback
        }

        var emitted: [CameraOptions] = []
        overlay.onPlacementChange = { emitted.append($0) }
        let seated = CameraOptions(enabled: true, widthFraction: 0.2, position: CameraPosition(x: 0, y: 0))
        overlay.applyPlacement(seated, source: .floating)
        let dragged = CameraOptions(enabled: true, widthFraction: 0.42, position: CameraPosition(x: 0.7, y: 0.3))

        overlay.applyPlacement(dragged, source: .floating, persists: false)
        #expect(emitted.last == dragged.resolved())
        #expect(RecordingSettings.load(from: defaults).camera == seated.resolved())

        overlay.applyPlacement(dragged, source: .floating, persists: true)
        #expect(RecordingSettings.load(from: defaults).camera == dragged.resolved())
        #expect(emitted.count == 3)
    }

    @Test("a finished recording releases the window confinement")
    @MainActor func recordingEndReleasesConfinement() throws {
        _ = NSApplication.shared
        let overlay = CameraOverlayController.shared
        let savedPreview = overlay.previewVisible
        defer {
            overlay.previewVisible = false
            overlay.recordingEnded()
            overlay.previewVisible = savedPreview
            overlay.hide()
        }

        let options = CameraOptions(enabled: true, widthFraction: 0.3, position: CameraPosition(x: 1, y: 0))
        let window = CGRect(x: 140, y: 160, width: 700, height: 420)
        let moved = CGRect(x: 620, y: 300, width: 700, height: 420)
        overlay.previewVisible = true
        overlay.prepareRecording(cgRect: window, options: options)
        let nativePanel = try #require(NSApp.windows.first { $0.contentView is FloatingCameraView })
        let confined = nativePanel.frame

        // Ending a recording that composited no camera must drop the recording bounds,
        // or the dead window rect keeps framing the free preview for the rest of the
        // session and every later drag normalizes against it.
        overlay.previewVisible = false
        overlay.recordingEnded()
        overlay.updateRecordingBounds(cgRect: moved)
        #expect(nativePanel.frame == confined)
    }

    @Test("stage camera geometry scales exactly with its thumbnail")
    @MainActor func stageThumbnailScale() {
        let frameSize = CGSize(width: 1600, height: 900)
        var options = CameraOptions(widthFraction: 0.3)
        options.position = CameraPosition(x: 0.27, y: 0.68)
        let small = CGRect(x: 8, y: 12, width: 320, height: 180)
        let large = CGRect(x: 16, y: 24, width: 640, height: 360)

        let a = StageView.cameraRect(options: options, frameSize: frameSize, thumbnail: small)
        let b = StageView.cameraRect(options: options, frameSize: frameSize, thumbnail: large)

        #expect(abs(b.minX - a.minX * 2) < 0.0001)
        #expect(abs(b.minY - a.minY * 2) < 0.0001)
        #expect(abs(b.width - a.width * 2) < 0.0001)
        #expect(abs(b.height - a.height * 2) < 0.0001)
    }

    @Test("an upward stage drag moves the y-up camera rectangle upward")
    @MainActor func stageDragUsesYUpCoordinates() {
        let frameSize = CGSize(width: 1600, height: 900)
        let thumbnail = CGRect(x: 0, y: 0, width: 320, height: 180)
        let translation = StageView.recordingTranslation(
            CGSize(width: 0, height: -20),
            frameSize: frameSize,
            thumbnail: thumbnail
        )
        var options = CameraOptions(widthFraction: 0.3, position: CameraPosition(x: 0.5, y: 0.4))
        let start = options.rect(in: frameSize)

        options.place(start.offsetBy(dx: translation.x, dy: translation.y), in: frameSize)

        #expect(abs(translation.y - 100) < 0.0001)
        #expect(options.rect(in: frameSize).minY > start.minY)
    }
}
