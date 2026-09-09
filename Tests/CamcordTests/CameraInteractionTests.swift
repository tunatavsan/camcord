import AppKit
import Testing

@testable import Camcord

@Suite("Camera interaction")
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
        let lag = 800 - motion.frame.minX
        #expect(lag > 10 && lag < 28)
        #expect(motion.magnetCorner == nil)
        motion.follow(CGPoint(x: 800, y: 350), released: true)
        for _ in 0..<90 { motion.step(seconds: 1.0 / 120) }
        #expect(motion.isSettled)
        #expect(abs(motion.frame.minX - 800) < 0.01)
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
            #expect(hypot(motion.frame.minX - previous.minX, motion.frame.minY - previous.minY) < 30)
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

    @Test("camera overlay is hidden after a panel hide without recording")
    @MainActor func panelHideClosesCameraOverlay() {
        _ = NSApplication.shared
        let controller = CameraOverlayController.shared
        controller.prepareRecording(
            cgRect: CGRect(x: -10_000, y: -10_000, width: 640, height: 360),
            options: CameraOptions(enabled: true)
        )
        #expect(controller.isVisible)

        controller.hide()

        #expect(!controller.isVisible)
    }
}
