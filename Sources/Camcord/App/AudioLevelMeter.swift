import SwiftUI

/// Audio measurements arrive at 30 Hz; native layers animate independently at the
/// display refresh rate, without recomputing the whole SwiftUI panel every frame.
struct AudioLevelMeter: View {
    let levels: AudioLevels?
    var active = true

    var body: some View {
        NativeAudioMeter(levels: levels, active: active)
            .frame(height: 7)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Ses seviyesi")
            .accessibilityValue(active ? "\(Int(levels?.rmsDBFS ?? -90)) dBFS" : "Etkin değil")
    }
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
        track.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        fill.colors = [NSColor.systemTeal.cgColor, NSColor.systemGreen.cgColor,
                       NSColor.systemYellow.cgColor, NSColor.systemOrange.cgColor]
        fill.locations = [0, 0.55, 0.84, 1]
        fill.startPoint = CGPoint(x: 0, y: 0.5)
        fill.endPoint = CGPoint(x: 1, y: 0.5)
        fillMask.backgroundColor = NSColor.white.cgColor
        fill.mask = fillMask
        peakMarker.backgroundColor = NSColor.labelColor.withAlphaComponent(0.85).cgColor
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

    private static func fraction(_ db: Double) -> Double {
        db.isFinite ? min(max((db + 60) / 60, 0), 1) : 0
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
        track.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
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
