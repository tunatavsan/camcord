import SwiftUI

/// The kit's live level meter. Audio measurements arrive at 30 Hz; native layers
/// animate independently at the display refresh rate, without recomputing the SwiftUI view every
/// frame, and the display link stops whenever the meter cannot be seen.
struct AudioLevelMeter: View {
    let levels: AudioLevels?
    var active = true
    var height: CGFloat = 6

    var body: some View {
        NativeAudioMeter(levels: levels, active: active)
            .frame(height: height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Level", comment: "Accessibility: an audio level meter"))
            .accessibilityValue(active
                ? Text("\(Int((levels?.rmsDBFS ?? -90).rounded())) dB", comment: "Accessibility: a level in decibels")
                : Text("Off", comment: "Accessibility value: a meter that is not measuring"))
    }
}

/// Where the meter's zones change colour, as fractions of its −60…0 dBFS scale.
enum MeterScale {
    static let floorDB = -60.0
    static let warnDB = -12.0
    static let hotDB = -6.0

    static func fraction(_ db: Double) -> Double {
        db.isFinite ? min(max((db - floorDB) / -floorDB, 0), 1) : 0
    }

    static var warnFraction: Double { fraction(warnDB) }
    static var hotFraction: Double { fraction(hotDB) }
}

/// Fast attack, gentle release, and a briefly held peak. Time-based response stays
/// the same on 60 Hz and 120 Hz displays, including when a frame arrives late.
struct AudioMeterMotion {
    private(set) var rms = 0.0
    private(set) var peak = 0.0
    private var peakHold = 0.0

    mutating func advance(rms targetRMS: Double, peak targetPeak: Double, elapsed: Double) {
        let dt = min(max(elapsed, 0), 0.1)
        let target = min(max(targetRMS, 0), 1)
        let duration = target > rms ? 0.022 : 0.20
        rms += (target - rms) * (1 - exp(-dt / duration))
        let nextPeak = min(max(targetPeak, 0), 1)
        if nextPeak >= peak {
            peak = nextPeak
            peakHold = 0.30
        } else {
            peakHold = max(0, peakHold - dt)
            if peakHold == 0 { peak = max(nextPeak, peak - dt * 0.40) }
        }
        if rms < 0.0001 { rms = 0 }
    }
}

private struct NativeAudioMeter: NSViewRepresentable {
    let levels: AudioLevels?
    let active: Bool

    func makeNSView(context: Context) -> AudioMeterView { AudioMeterView() }
    func updateNSView(_ view: AudioMeterView, context: Context) {
        view.update(levels: levels, active: active)
    }
    static func dismantleNSView(_ view: AudioMeterView, coordinator: ()) { view.stop() }
}

@MainActor
private final class AudioMeterView: NSView {
    private let track = CALayer()
    private let fill = CAGradientLayer()
    private let fillMask = CALayer()
    private let peakMarker = CALayer()
    private var motion = AudioMeterMotion()
    private var targetRMS = 0.0
    private var targetPeak = 0.0
    private var active = false
    private var previousTimestamp: CFTimeInterval?
    private var displayLink: CADisplayLink?
    private var observer: NSObjectProtocol?
    private lazy var proxy = MeterDisplayProxy(view: self)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // Three hard zones (Console): normal up to −12 dBFS, warn to −6, hot above.
        let warn = NSNumber(value: MeterScale.warnFraction), hot = NSNumber(value: MeterScale.hotFraction)
        fill.locations = [0, warn, warn, hot, hot, 1]
        fill.startPoint = CGPoint(x: 0, y: 0.5)
        fill.endPoint = CGPoint(x: 1, y: 0.5)
        fill.mask = fillMask
        applyColors()
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
        layer?.addSublayer(peakMarker)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    isolated deinit {
        displayLink?.invalidate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func update(levels: AudioLevels?, active: Bool) {
        self.active = active
        targetRMS = active ? Self.fraction(levels?.rmsDBFS ?? -90) : 0
        targetPeak = active ? Self.fraction(levels?.peakDBFS ?? -90) : 0
        if !active {
            motion = AudioMeterMotion()
            render()
        }
        updateDisplayLink()
    }

    private static func fraction(_ db: Double) -> Double { MeterScale.fraction(db) }

    /// Layers hold resolved colours; they are re-resolved whenever the appearance changes.
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let low = Theme.Palette.meterLow.ns.cgColor
            let mid = Theme.Palette.meterMid.ns.cgColor
            let high = Theme.Palette.meterHigh.ns.cgColor
            track.backgroundColor = Theme.Palette.meterOff.ns.cgColor
            fill.colors = [low, low, mid, mid, high, high]
            fillMask.backgroundColor = Theme.Palette.ink.ns.cgColor   // a mask: only the alpha counts
            peakMarker.backgroundColor = Theme.Palette.ink.ns.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let window {
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateDisplayLink() }
            }
        }
        updateDisplayLink()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        configureFrameRate()
    }

    override func layout() {
        super.layout()
        render()
    }

    private func updateDisplayLink() {
        guard active, let window, window.isVisible,
              window.occlusionState.contains(.visible), !isHiddenOrHasHiddenAncestor
        else { stop(); return }
        guard displayLink == nil else { return }
        let link = self.displayLink(target: proxy, selector: #selector(MeterDisplayProxy.tick(_:)))
        displayLink = link
        configureFrameRate()
        link.add(to: .main, forMode: .common)
    }

    private func configureFrameRate() {
        let fps = Float(min(120, max(30, window?.screen?.maximumFramesPerSecond ?? 60)))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, fps), maximum: fps, preferred: fps)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        previousTimestamp = nil
    }

    func tick(_ link: CADisplayLink) {
        let dt = previousTimestamp.map { link.timestamp - $0 } ?? 1 / 120
        previousTimestamp = link.timestamp
        motion.advance(rms: targetRMS, peak: targetPeak, elapsed: dt)
        render()
    }

    private func render() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        track.cornerRadius = bounds.height / 2
        fill.frame = bounds
        fill.cornerRadius = bounds.height / 2
        fill.masksToBounds = true
        fillMask.frame = CGRect(x: 0, y: 0, width: bounds.width * motion.rms, height: bounds.height)
        fillMask.cornerRadius = bounds.height / 2
        peakMarker.frame = CGRect(x: max(0, (bounds.width - 2) * motion.peak), y: 0,
                                  width: 2, height: bounds.height)
        peakMarker.cornerRadius = 1
        peakMarker.opacity = motion.peak > 0.001 && active ? 1 : 0
        CATransaction.commit()
    }
}

@MainActor
private final class MeterDisplayProxy: NSObject {
    weak var view: AudioMeterView?
    init(view: AudioMeterView) { self.view = view }
    @objc func tick(_ link: CADisplayLink) { view?.tick(link) }
}
