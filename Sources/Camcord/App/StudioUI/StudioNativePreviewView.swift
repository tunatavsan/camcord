import AppKit
import AVFoundation
import SwiftUI

/// The view owns presentation geometry; the session owns all capture and renderer work.
@MainActor protocol StudioPreviewHostSession: AnyObject {
    func attachPreviewHost(_ layer: AVSampleBufferDisplayLayer, viewport: StudioPreviewViewport) -> UUID
    func updatePreviewViewport(_ viewport: StudioPreviewViewport, owner: UUID)
    func detachPreviewHost(owner: UUID)
}

extension StudioSession: StudioPreviewHostSession {}

struct StudioNativePreviewView: NSViewRepresentable {
    let session: StudioSession

    func makeNSView(context: Context) -> StudioNativePreviewHost {
        let view = StudioNativePreviewHost()
        view.configure(session: session)
        return view
    }

    func updateNSView(_ view: StudioNativePreviewHost, context: Context) {
        view.configure(session: session)
    }

    static func dismantleNSView(_ view: StudioNativePreviewHost, coordinator: ()) {
        view.detachSession()
    }
}

@MainActor final class StudioNativePreviewHost: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    private weak var session: (any StudioPreviewHostSession)?
    private var owner: UUID?
    private var submittedViewport: StudioPreviewViewport?
    private var screenObservation: NSObjectProtocol?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        wantsLayer = true
        displayLayer.videoGravity = .resizeAspect
        layer?.addSublayer(displayLayer)
        setAccessibilityElement(true)
        setAccessibilityLabel(String(localized: "Recording preview"))
    }

    required init?(coder: NSCoder) { nil }

    func configure(session next: any StudioPreviewHostSession) {
        if let session, session === next {
            updateViewport()
            return
        }
        detachSession()
        session = next
        observeWindowScreen()
        updateViewport()
    }

    func detachSession() {
        if let owner { session?.detachPreviewHost(owner: owner) }
        owner = nil
        session = nil
        submittedViewport = nil
        removeScreenObservation()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        displayLayer.contentsScale = window?.backingScaleFactor ?? 1
        CATransaction.commit()
        updateViewport()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
        updateViewport()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindowScreen()
        needsLayout = true
        updateViewport()
    }

    private func observeWindowScreen() {
        removeScreenObservation()
        if let observedWindow = window, session != nil {
            screenObservation = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification, object: observedWindow, queue: .main
            ) { [weak self, weak observedWindow] _ in
                Task { @MainActor [weak self, weak observedWindow] in
                    guard let self, let observedWindow, self.window === observedWindow else { return }
                    self.needsLayout = true
                    self.updateViewport()
                }
            }
        }
    }

    private func removeScreenObservation() {
        if let screenObservation { NotificationCenter.default.removeObserver(screenObservation) }
        screenObservation = nil
    }

    private func updateViewport() {
        guard let session, let viewport = Self.viewport(
            backingSize: convertToBacking(bounds).size,
            maximumFramesPerSecond: window?.screen?.maximumFramesPerSecond ?? 60
        ) else { return }
        guard viewport != submittedViewport else { return }
        if let owner { session.updatePreviewViewport(viewport, owner: owner) }
        else { owner = session.attachPreviewHost(displayLayer, viewport: viewport) }
        submittedViewport = viewport
    }

    static func viewport(backingSize: CGSize, maximumFramesPerSecond: Int) -> StudioPreviewViewport? {
        guard backingSize.width.isFinite, backingSize.height.isFinite,
              backingSize.width >= 2, backingSize.height >= 2 else { return nil }
        let size = CGSize(width: floor(backingSize.width / 2) * 2,
                          height: floor(backingSize.height / 2) * 2)
        return StudioPreviewViewport(pixelSize: size, refreshRate: maximumFramesPerSecond >= 100 ? 120 : 60)
    }
}
