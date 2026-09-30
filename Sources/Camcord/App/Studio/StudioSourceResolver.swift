import AppKit
@preconcurrency import ScreenCaptureKit

@MainActor
enum StudioSourceResolver {
    static func choices(in content: SCShareableContent, settings: RecordingSettings) -> [StudioSourceChoice] {
        let displays = content.displays.sorted { $0.displayID < $1.displayID }.map { display in
            StudioSourceChoice(id: .display(display.displayID), title: String(format: String(localized: "Display %u", comment: "Studio source title: display identifier"), display.displayID),
                               frame: display.frame, pixelSize: pixelSize(of: .display(display, scale: scale(display), excluding: nil),
                                                                          settings: settings))
        }
        let windows = content.windows.filter { window in
            window.windowID != 0 && window.frame.width > 1 && window.frame.height > 1
                && window.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
                && window.windowLayer == 0
        }.sorted { $0.windowID < $1.windowID }.map { window in
            let application = window.owningApplication?.applicationName ?? String(localized: "Window", comment: "Studio source title fallback")
            let title = window.title?.isEmpty == false ? "\(application) — \(window.title!)" : application
            return StudioSourceChoice(id: .window(window.windowID), title: title, frame: window.frame,
                                      pixelSize: pixelSize(of: .window(window), settings: settings))
        }
        return displays + windows
    }

    static func resolve(_ choice: StudioSourceChoice, in content: SCShareableContent,
                        settings: RecordingSettings) throws -> RecordingEngine.Target {
        let ownApp = content.applications.first { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        switch choice.id {
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }),
                  window.frame.width > 1, window.frame.height > 1,
                  window.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier else { throw StudioIssue.sourceUnavailable }
            return .window(window)
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw StudioIssue.sourceUnavailable }
            return .display(display, scale: settings.captureScale(displayScale: scale(display), gameLike: false), excluding: ownApp)
        case .region(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }),
                  let clamp = RegionClamp.clamp(region: choice.frame, displays: [
                    .init(frame: display.frame, scale: scale(display))
                  ]), clamp.pixelWidth >= 2, clamp.pixelHeight >= 2 else { throw StudioIssue.sourceUnavailable }
            return .region(clamp, display, excluding: ownApp)
        }
    }

    static func pixelSize(of target: RecordingEngine.Target, settings: RecordingSettings) -> CGSize {
        switch target {
        case .region(let clamp, _, _):
            return settings.resolutionScale == .native
                ? CGSize(width: clamp.pixelWidth, height: clamp.pixelHeight) : clamp.clampedRegion.size
        case .display(let display, let scale, _):
            let multiplier = settings.resolutionScale == .native ? scale : 1
            return CGSize(width: RegionClamp.evenFloor(display.frame.width * multiplier),
                          height: RegionClamp.evenFloor(display.frame.height * multiplier))
        case .window(let window):
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let frame = Geometry.cgToAppKit(window.frame, primaryScreenHeight: primaryHeight)
            let intersected = NSScreen.screens.filter { $0.frame.intersects(frame) }
            let screen = intersected.first ?? NSScreen.main
            let backingScale = screen?.backingScaleFactor ?? 1
            let doubleScaled = (intersected.count <= 1 && filter.contentRect.width > (screen?.frame.width ?? 0) + 10)
                || CGFloat(filter.pointPixelScale) > backingScale
            let effective = doubleScaled ? 1 : CGFloat(filter.pointPixelScale)
            let physical = CGSize(width: filter.contentRect.width * effective, height: filter.contentRect.height * effective)
            let windowSize = settings.resolutionScale == .native ? physical
                : CGSize(width: physical.width / (doubleScaled ? backingScale : CGFloat(filter.pointPixelScale)),
                         height: physical.height / (doubleScaled ? backingScale : CGFloat(filter.pointPixelScale)))
            let displaySize = settings.resolutionScale == .native
                ? CGSize(width: (screen?.frame.width ?? 0) * backingScale, height: (screen?.frame.height ?? 0) * backingScale)
                : screen?.frame.size ?? .zero
            let size = settings.canvasAspect.canvasSize(window: windowSize, display: displaySize)
            return CGSize(width: size.width, height: size.height)
        }
    }

    static func scale(_ display: SCDisplay) -> CGFloat {
        NSScreen.screens.first { $0.cgDirectDisplayID == display.displayID }?.backingScaleFactor ?? 1
    }
}
