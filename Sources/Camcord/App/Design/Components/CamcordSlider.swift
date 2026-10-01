import AppKit
import SwiftUI

/// A continuous native slider with Camcord's slim track. NSSlider retains tracking,
/// keyboard input and accessibility; the caller owns value rounding and formatting.
struct CamcordSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(frame: .zero)
        slider.cell = CamcordSliderCell()
        slider.isContinuous = true
        slider.setAccessibilityElement(true)
        slider.setAccessibilityRole(.slider)
        slider.numberOfTickMarks = 0
        slider.allowsTickMarkValuesOnly = false
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.isEnabled = isEnabled
        slider.needsDisplay = true
    }

    @MainActor final class Coordinator: NSObject {
        var value: Binding<Double>
        init(value: Binding<Double>) { self.value = value }
        @objc func changed(_ slider: NSSlider) { value.wrappedValue = slider.doubleValue }
    }
}

@MainActor private final class CamcordSliderCell: NSSliderCell {
    override var knobThickness: CGFloat { Theme.Studio.gainKnob }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - Theme.Studio.gainTrack / 2,
                           width: rect.width, height: Theme.Studio.gainTrack)
        Theme.Palette.hairlineStrong.ns.setFill()
        NSBezierPath(roundedRect: track, xRadius: Theme.Studio.gainTrack / 2,
                     yRadius: Theme.Studio.gainTrack / 2).fill()
    }

    override func drawKnob(_ knobRect: NSRect) {
        let diameter = Theme.Studio.gainKnob
        let knob = NSRect(x: knobRect.midX - diameter / 2, y: knobRect.midY - diameter / 2,
                          width: diameter, height: diameter)
        (isEnabled ? Theme.Palette.ink.ns : Theme.Palette.ink3.ns).setFill()
        NSBezierPath(ovalIn: knob).fill()
    }
}
