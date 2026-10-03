import ApplicationServices
import CoreGraphics
import Foundation

/// What moves the page during an auto scroll. One step at a time: the session waits for the
/// page to settle and measures the real shift from the captured frames before the next step,
/// so no actuator has to be exact — only calm.
@MainActor
protocol ScrollActuator: AnyObject {
    /// For the diagnostics line.
    var route: String { get }
    /// Moves the content by `points`: positive reveals what is below, negative what is above.
    /// False when the step could not be made now (the pointer left the region) — try again.
    func scroll(by points: CGFloat) async -> Bool
    /// Jumps straight to the top when the route can; false means climb step by step.
    func jumpToTop() async -> Bool
    /// The page moved the other way: steps run reversed from now on.
    func reverse()
    /// How far the content is scrolled, in points, where the route can read it.
    func position() -> CGFloat?
}

/// AppKit and WebKit scroll areas expose their vertical scroll bar to Accessibility, and
/// setting its value moves the content in one exact jump — no animation, no rubber band, no
/// cursor, and nothing a scroll smoother on the Mac can rewrite.
@MainActor
final class AXScrollActuator: ScrollActuator {
    let route = "ax"
    private let area: AXUIElement
    private let bar: AXUIElement
    private let content: AXUIElement

    private init(area: AXUIElement, bar: AXUIElement, content: AXUIElement) {
        self.area = area
        self.bar = bar
        self.content = content
    }

    /// The scroll area under the region's centre (CG global coordinates), if it is the one the
    /// region shows and its scroll bar takes a value. Nil sends the session to wheel events.
    static func resolve(region: CGRect) async -> AXScrollActuator? {
        let centre = CGPoint(x: region.midX, y: region.midY)
        guard let pid = ownerOfWindow(at: centre) else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        // An app builds its accessibility tree only once someone asks: until then a hit test
        // answers "not implemented". Asking for its windows wakes it.
        let _: [AXUIElement]? = attribute(app, kAXWindowsAttribute)
        var found: AXUIElement?
        for attempt in 0..<3 {
            found = scrollAreaByHitTest(app, at: centre) ?? scrollAreaBySearch(app, at: centre)
            if found != nil { break }
            if attempt < 2 { try? await Task.sleep(for: .milliseconds(200)) }
        }
        guard let area = found,
              let bar: AXUIElement = attribute(area, kAXVerticalScrollBarAttribute),
              isSettable(bar, kAXValueAttribute),
              let areaFrame = frame(of: area) else { return nil }
        // The scroll area must be the one the region shows, not a page around a nested
        // scroller: it covers most of the region.
        let covered = areaFrame.intersection(region)
        guard !covered.isNull, covered.width * covered.height >= 0.6 * region.width * region.height else { return nil }
        let children: [AXUIElement] = attribute(area, kAXChildrenAttribute) ?? []
        guard let content = children.first(where: { child in
            !CFEqual(child, bar) && (frame(of: child)?.height ?? 0) > areaFrame.height - 1
        }) else { return nil }
        let actuator = AXScrollActuator(area: area, bar: bar, content: content)
        guard let geometry = actuator.geometry(), geometry.max > 1 else { return nil }
        return actuator
    }

    /// The scroll area around the element under `point`.
    private static func scrollAreaByHitTest(_ app: AXUIElement, at point: CGPoint) -> AXUIElement? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success,
              var element = hit else { return nil }
        for _ in 0..<16 {
            if role(of: element) == kAXScrollAreaRole as String { return element }
            guard let parent: AXUIElement = attribute(element, kAXParentAttribute) else { return nil }
            element = parent
        }
        return nil
    }

    /// Without a hit test: down from the app's windows to the innermost scroll area holding
    /// `point`, never into the (huge) content of a web page, a text, a table or a list.
    private static func scrollAreaBySearch(_ app: AXUIElement, at point: CGPoint) -> AXUIElement? {
        let opaque: Set<String> = ["AXWebArea", kAXTextAreaRole as String, kAXTableRole as String,
                                   kAXListRole as String, kAXOutlineRole as String, kAXBrowserRole as String]
        var queue: [(AXUIElement, Int)] = ((attribute(app, kAXWindowsAttribute) as [AXUIElement]?) ?? []).map { ($0, 0) }
        var best: (element: AXUIElement, area: CGFloat)?
        var visited = 0
        while !queue.isEmpty, visited < 1_500 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            guard let rect = frame(of: element), rect.contains(point) else { continue }
            let role = role(of: element) ?? ""
            if role == kAXScrollAreaRole as String, rect.width * rect.height < (best?.area ?? .infinity) {
                best = (element, rect.width * rect.height)
            }
            guard depth < 14, !opaque.contains(role) else { continue }
            for child in (attribute(element, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { queue.append((child, depth + 1)) }
        }
        return best?.element
    }

    /// The frontmost ordinary window under `point` that is not Camcord's own.
    private static func ownerOfWindow(at point: CGPoint) -> pid_t? {
        let own = getpid()
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for window in windows {
            // Below the Dock's level (its full-screen layer is not a target), and visible.
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  (window[kCGWindowLayer as String] as? Int) ?? 0 < 20,
                  (window[kCGWindowAlpha as String] as? Double) ?? 1 > 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.contains(point) else { continue }
            return pid
        }
        return nil
    }

    func position() -> CGFloat? { geometry()?.offset }

    /// How far the content is scrolled and how far it can go, in points.
    func geometry() -> (offset: CGFloat, max: CGFloat)? {
        guard let areaFrame = Self.frame(of: area), let contentFrame = Self.frame(of: content) else { return nil }
        return (areaFrame.minY - contentFrame.minY, max(0, contentFrame.height - areaFrame.height))
    }

    func scroll(by points: CGFloat) async -> Bool {
        guard let geometry = geometry(), geometry.max > 0 else { return false }
        let target = min(max(geometry.offset + points, 0), geometry.max)
        return await set(target / geometry.max, from: geometry.offset)
    }

    /// The scroll bar's direction is the content's; nothing to reverse.
    func reverse() {}

    func jumpToTop() async -> Bool {
        guard let geometry = geometry() else { return false }
        guard geometry.offset > 0.5 else { return true }
        return await set(0, from: geometry.offset)
    }

    /// WebKit applies the value a moment later; wait (briefly) until the content has moved.
    private func set(_ value: CGFloat, from offset: CGFloat) async -> Bool {
        guard AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: Double(value))) == .success
        else { return false }
        let deadline = ContinuousClock.now + .milliseconds(400)
        while ContinuousClock.now < deadline {
            if let now = geometry(), abs(now.offset - offset) > 0.5 { return true }
            try? await Task.sleep(for: .milliseconds(16))
        }
        return true
    }

    private static func role(of element: AXUIElement) -> String? { attribute(element, kAXRoleAttribute) }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position: AXValue = attribute(element, kAXPositionAttribute),
              let size: AXValue = attribute(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}

/// Everything else (Chromium, Electron, Firefox, nested scrollers): ONE precise pixel wheel
/// event per step, with no gesture or momentum phase, which every engine applies at once and
/// exactly. It carries the mark scroll smoothers such as Mos leave alone, so they never
/// reverse, smooth or fling it. Wheel events go to the window under the pointer: the pointer
/// is parked in the region, and while the owner moves it away nothing is posted.
@MainActor
final class WheelScrollActuator: ScrollActuator {
    let route = "wheel"
    /// The marker Mos checks before rewriting an event; events carrying it pass untouched.
    static let smootherBypass: Int64 = 0x4D4F_5353_4D4F_4F54
    private let region: CGRect
    /// Positive wheel values scroll toward the top for synthetic events, whatever the Natural
    /// Scrolling setting; the session flips it once if the first step measures otherwise.
    private(set) var sign: Int32 = -1
    private let source = CGEventSource(stateID: .hidSystemState)
    private static let strayTolerance: CGFloat = 4

    init(region: CGRect) {
        self.region = region
        CGWarpMouseCursorPosition(CGPoint(x: region.midX, y: region.midY))
    }

    func reverse() { sign = -sign }

    func scroll(by points: CGFloat) async -> Bool {
        if let here = CGEvent(source: nil)?.location,
           !region.insetBy(dx: -Self.strayTolerance, dy: -Self.strayTolerance).contains(here) { return false }
        // Large single values are applied unevenly; split a long step into a short burst.
        let total = Int32(points.rounded())
        let parts = max(1, Int((abs(points) / 600).rounded(.up)))
        var sent: Int32 = 0
        for part in 0..<parts {
            let value = part == parts - 1 ? total - sent : total / Int32(parts)
            sent += value
            guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                                      wheel1: sign * value, wheel2: 0, wheel3: 0) else { return false }
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.eventSourceUserData, value: Self.smootherBypass)
            event.post(tap: .cghidEventTap)
            if part < parts - 1 { try? await Task.sleep(for: .milliseconds(16)) }
        }
        return true
    }

    func jumpToTop() async -> Bool { false }

    func position() -> CGFloat? { nil }

    /// True for an event this process posted, however it echoes back through a monitor.
    static func isOwnEvent(_ event: CGEvent?) -> Bool {
        guard let event else { return false }
        return event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid())
    }
}
