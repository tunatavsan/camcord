import AppKit
import CoreGraphics

/// The trackpad's pinch and smart zoom for Camcord's floating surfaces. A pin or a card never
/// takes the focus from the app in front, and the system hands a gesture to the app in front,
/// not to the window under the fingers, so they never saw one. A session event tap sees every
/// gesture first: one made over a registered surface is given to it and kept from the app in
/// front; every other passes untouched. Without Accessibility there is no tap, and a surface
/// sees only the gestures the system sends it.
@MainActor final class GestureTap {
    static let shared = GestureTap()
    /// A pinch step or a smart zoom.
    struct Gesture: Sendable {
        enum Kind: Sendable { case pinch, smartZoom }
        let kind: Kind
        let magnification: CGFloat
        let phase: NSEvent.Phase
    }
    /// Takes a pinch or smart zoom made over the window; true when it used it.
    typealias Handler = @MainActor (Gesture) -> Bool
    private struct Entry {
        weak var window: NSWindow?
        let handler: Handler
    }
    private var entries: [UUID: Entry] = [:]
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var loggedGesture = false

    /// - Returns: the registration, to end it with `unregister`.
    func register(_ window: NSWindow, handler: @escaping Handler) -> UUID {
        let id = UUID()
        entries[id] = Entry(window: window, handler: handler)
        install()
        return id
    }

    func unregister(_ id: UUID?) {
        guard let id else { return }
        entries[id] = nil
        if entries.isEmpty { uninstall() }
    }

    private func install() {
        guard tap == nil else { return }
        let mask = CGEventMask(1) << CGEventMask(NSEvent.EventType.magnify.rawValue)
            | CGEventMask(1) << CGEventMask(NSEvent.EventType.smartMagnify.rawValue)
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: gestureTapCallback, userInfo: info) else {
            DiagnosticsLog.append("gesture tap unavailable")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        self.source = source
    }

    private func uninstall() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// True when a surface under the pointer took the gesture.
    fileprivate func handle(_ gesture: Gesture) -> Bool {
        let point = NSEvent.mouseLocation
        // Our windows front to back: the first registered one under the pointer takes it.
        // Panels are not in `orderedWindows`; window numbers are, front to back.
        let front = (NSWindow.windowNumbers(options: []) ?? []).compactMap { NSApp.window(withWindowNumber: $0.intValue) }
        for window in front where window.isVisible && window.frame.contains(point) {
            guard let entry = entries.values.first(where: { $0.window === window }) else { continue }
            if !loggedGesture || gesture.phase == .began {
                loggedGesture = true
                DiagnosticsLog.append("gesture tap kind=\(gesture.kind) phase=\(gesture.phase.rawValue) window=\(window.windowNumber)")
            }
            return entry.handler(gesture)
        }
        return false
    }
}

private func gestureTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let info else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<GestureTap>.fromOpaque(info).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { tap.reenable() }
        return Unmanaged.passUnretained(event)
    }
    guard let read = NSEvent(cgEvent: event), read.type == .magnify || read.type == .smartMagnify else {
        return Unmanaged.passUnretained(event)
    }
    let gesture = GestureTap.Gesture(kind: read.type == .magnify ? .pinch : .smartZoom,
                                     magnification: read.type == .magnify ? read.magnification : 0, phase: read.phase)
    let taken = MainActor.assumeIsolated { tap.handle(gesture) }
    return taken ? nil : Unmanaged.passUnretained(event)
}
