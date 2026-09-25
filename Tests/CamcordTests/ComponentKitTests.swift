import AppKit
import SwiftUI
import Testing

@testable import Camcord

/// The component kit's logic (docs/design/native/SPEC.md §3): the capture kinds, the mark and
/// the capture brackets, the timecode and tally sweep, the meter scale, and condense under
/// Reduce Motion.
@MainActor
@Suite("Component kit")
struct ComponentKitTests {
    @Test("five captures, one name each, real SF Symbols, one hotkey each")
    func captureKinds() {
        #expect(CaptureKind.allCases.map(\.rawValue) == ["region", "window", "screen", "scroll", "text"])
        #expect(Set(CaptureKind.allCases.map(\.symbol)).count == 5)
        #expect(Set(CaptureKind.allCases.map(\.shortcutName.rawValue)).count == 5)
        #expect(Set(CaptureKind.allCases.map(\.title.key)).count == 5)
        #expect(CaptureKind.scroll.title.key == "Scroll capture")
        #expect(CaptureKind.scroll.shortTitle.key == "Scroll")
        #expect(CaptureKind.region.shortTitle.key == CaptureKind.region.title.key)
        for kind in CaptureKind.allCases {
            #expect(NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil) != nil, "\(kind.symbol)")
        }
    }

    @Test("the mark is four brackets filling a centred square; capture brackets sit `inset` outside")
    func brackets() {
        let mark = ViewfinderMark().path(in: CGRect(x: 0, y: 0, width: 100, height: 60))
        #expect(mark.boundingRect == CGRect(x: 20, y: 0, width: 60, height: 60))
        var subpaths = 0
        mark.forEach { if case .move = $0 { subpaths += 1 } }
        #expect(subpaths == 4)

        let rect = CGRect(x: 10, y: 10, width: 300, height: 120)
        let snapped = CaptureBrackets(inset: 0).path(in: rect).boundingRect
        let loose = CaptureBrackets(inset: 18).path(in: rect).boundingRect
        #expect(abs(snapped.minX - rect.minX) < 0.01 && abs(snapped.maxY - rect.maxY) < 0.01)
        #expect(abs(loose.minX - (rect.minX - 18)) < 0.01 && abs(loose.width - (rect.width + 36)) < 0.01)
        // The arms keep their length on a wide rect instead of stretching with it.
        var arm = CaptureBrackets(inset: 0)
        arm.animatableData = 5
        #expect(arm.inset == 5)
    }

    @Test("the status-item mark is a template image of the asked size")
    func templateImage() {
        let image = ViewfinderMarkView.templateImage(size: 18)
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
    }

    @Test("timecode: mm:ss under an hour, h:mm:ss above; the sweep turns once a minute")
    func timecode() {
        #expect(Timecode.format(0) == "00:00")
        #expect(Timecode.format(266.9) == "04:26")
        #expect(Timecode.format(3866) == "1:04:26")
        #expect(Timecode.format(-5) == "00:00")
        #expect(Timecode.format(.nan) == "00:00")
        #expect(Timecode.sweep(0) == 0)
        #expect(abs(Timecode.sweep(15) - 0.25) < 1e-9)
        #expect(abs(Timecode.sweep(75) - 0.25) < 1e-9)
        #expect(!Timecode.spoken(266).isEmpty)
    }

    @Test("the meter's scale: −60…0 dBFS, warn from −12, hot from −6")
    func meterScale() {
        #expect(MeterScale.fraction(-60) == 0)
        #expect(MeterScale.fraction(0) == 1)
        #expect(MeterScale.fraction(-90) == 0)
        #expect(MeterScale.fraction(6) == 1)
        #expect(MeterScale.fraction(.nan) == 0)
        #expect(abs(MeterScale.warnFraction - 0.8) < 1e-9)
        #expect(abs(MeterScale.hotFraction - 0.9) < 1e-9)
    }

    @Test("condense arrives from a blur and 96 %; under Reduce Motion it only fades")
    func condense() {
        let full = CondenseTransition.values(identity: false, reduceMotion: false)
        #expect(full.opacity == 0 && full.scale == Theme.Motion.condenseScale && full.blur == Theme.Motion.condenseBlur)
        let reduced = CondenseTransition.values(identity: false, reduceMotion: true)
        #expect(reduced.opacity == 0 && reduced.scale == 1 && reduced.blur == 0)
        let rest = CondenseTransition.values(identity: true, reduceMotion: false)
        #expect(rest.opacity == 1 && rest.scale == 1 && rest.blur == 0)
    }

    @Test("ink navigation: arrows move one step among the ids and stop at the ends (KARAR-1)")
    func inkNavigation() {
        let order = ["library", "studio", "edit", "settings"]
        #expect(InkNavigation.move(from: "library", by: 1, in: order) == "studio")
        #expect(InkNavigation.move(from: "studio", by: -1, in: order) == "library")
        #expect(InkNavigation.move(from: "library", by: -1, in: order) == "library")
        #expect(InkNavigation.move(from: "settings", by: 1, in: order) == "settings")
        #expect(InkNavigation.move(from: "timeline", by: 1, in: order) == "library")
        #expect(InkNavigation.move(from: "x", by: 1, in: [String]()) == "x")
    }

    @Test("window backdrops: a translucent tint over a system material, opaque under Reduce Transparency")
    func windowBackdrops() {
        for backdrop in WindowBackdrop.allCases {
            for variant in ThemeColor.Variant.allCases {
                #expect(backdrop.tint.value(variant).alpha < 1, "\(backdrop) \(variant)")
                #expect(backdrop.solid.value(variant).alpha == 1, "\(backdrop) \(variant)")
            }
        }
        #expect(WindowBackdrop.sidebar.material == .sidebar)
        #expect(WindowBackdrop.content.material == .underWindowBackground)
        // The sidebar reads lighter than the content, in both appearances.
        for variant in [ThemeColor.Variant.dark, .light] {
            let sidebar = WindowBackdrop.sidebar.tint.value(variant), content = WindowBackdrop.content.tint.value(variant)
            #expect(variant == .dark ? sidebar.luminance > content.luminance : sidebar.luminance < content.luminance)
        }
    }
}
