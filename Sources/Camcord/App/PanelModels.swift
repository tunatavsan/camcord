import AVFoundation
import AppKit
import KeyboardShortcuts
import SwiftUI

/// Shared recording state for SwiftUI surfaces (the panel). Pushed by
/// `RecordingController.onUIChange` via AppDelegate — single source of truth, the
/// same feed that drives the status-item glyph.
@MainActor
final class RecordingStateModel: ObservableObject {
    @Published var state: RecordingController.UIState = .idle
    @Published var elapsed: String?
    @Published var health: RecordingHealth?
    /// True from the moment Stop is pressed until the file is finalized on disk.
    @Published var isFinishing = false
    /// The just-finished recording, shown as a "done" card until dismissed / reopened.
    @Published var finishedURL: URL?
    /// Bumped by PanelController on every show. The popover's hosting controller is
    /// retained across shows, so `@State` persists and `onAppear` fires only once —
    /// this token re-reads persisted toggles per open.
    @Published var panelOpenToken = 0
    @Published var isPanelVisible = false
    @Published var isStarting = false
    @Published var isArmed = false
}

/// What a press on the recording stage landed on.
struct StageHit: Equatable, Sendable {
    let corner: CameraCorner?
    let movesCamera: Bool
}

/// The stage's camera rectangle is ~54×31 pt: the floating tile's 44 pt corner zones would
/// cover almost all of it. Here the whole body moves and only small corner zones resize —
/// `max(12 pt, 22% of the side)` on each axis, never more than half of it — and the grips
/// that mark them are drawn INSIDE the rectangle, where a press actually lands.
enum StageGrip {
    static let minimumZone: CGFloat = 12
    static let zoneFraction: CGFloat = 0.22
    /// Radius of the corner curve the grip arcs follow, and their gap inside it.
    static let arcRadius: CGFloat = 5
    static let arcGap: CGFloat = 1.5
    static let strokeWidth: CGFloat = 1

    /// A corner's resize zone, inside `rect` (any y direction: the zones are symmetric).
    static func zone(_ corner: CameraCorner, in rect: CGRect, yDown: Bool = false) -> CGRect {
        let width = min(max(minimumZone, rect.width * zoneFraction), rect.width / 2)
        let height = min(max(minimumZone, rect.height * zoneFraction), rect.height / 2)
        let right = corner == .topRight || corner == .bottomRight
        let top = corner == .topLeft || corner == .topRight
        let atMaxY = yDown ? !top : top
        return CGRect(x: right ? rect.maxX - width : rect.minX,
                      y: atMaxY ? rect.maxY - height : rect.minY, width: width, height: height)
    }

    /// The zones lie inside `rect`, so a point outside it is never on a grip.
    static func corner(at point: CGPoint, in rect: CGRect, yDown: Bool = false) -> CameraCorner? {
        CameraCorner.allCases.first { zone($0, in: rect, yDown: yDown).contains(point) }
    }

    /// A quarter arc just inside `corner`, concentric with the rectangle's own corner curve
    /// (y-down, the SwiftUI canvas).
    static func arc(_ corner: CameraCorner, in rect: CGRect) -> Path {
        let radius = max(arcRadius, CameraOptions.cornerRadius(for: rect.size))
        let right = corner == .topRight || corner == .bottomRight
        let top = corner == .topLeft || corner == .topRight
        let center = CGPoint(x: right ? rect.maxX - radius : rect.minX + radius,
                             y: top ? rect.minY + radius : rect.maxY - radius)
        let start: Double
        switch corner {
        case .topLeft: start = 180
        case .topRight: start = 270
        case .bottomRight: start = 0
        case .bottomLeft: start = 90
        }
        var path = Path()
        path.addArc(center: center, radius: radius - arcGap, startAngle: .degrees(start),
                    endAngle: .degrees(start + 90), clockwise: false)
        return path
    }

    /// The pointer a hover shows: open hand over the body, a resize arrow on a grip.
    static func cursor(for hit: StageHit) -> StageCursor? {
        guard hit.movesCamera else { return nil }
        return hit.corner.map(StageCursor.resize) ?? .move
    }
}

enum StageCursor: Equatable {
    case move
    case resize(CameraCorner)

    var style: PointerStyle {
        switch self {
        case .move: return .grabIdle
        case .resize(let corner):
            switch corner {
            case .topLeft: return .frameResize(position: .topLeading)
            case .topRight: return .frameResize(position: .topTrailing)
            case .bottomLeft: return .frameResize(position: .bottomLeading)
            case .bottomRight: return .frameResize(position: .bottomTrailing)
            }
        }
    }
}

/// One still frame of the armed window, with the size the recording will composite
/// into — enough for the panel to draw the camera rectangle before a recording exists.
struct ArmedStageFrame: Sendable {
    let image: CGImage
    let frameSize: CGSize
}

/// The panel's actions, injected by AppDelegate. Each closure owns its own
/// popover-closing/delay choreography.
@MainActor
struct PanelActions {
    var captureText: () -> Void = {}
    var openLibrary: () -> Void = {}
    var openEditor: () -> Void = {}
    var openStudio: () -> Void = {}
    var quit: () -> Void = { NSApp.terminate(nil) }
    var captureRegion: () -> Void = {}
    var captureWindow: () -> Void = {}
    var captureScreen: () -> Void = {}
    /// Scrolling capture — the whole scrollable area stitched into one tall image.
    var captureScroll: () -> Void = {}
    /// Start an interactive recording when idle; stop it otherwise.
    var toggleRecording: () -> Void = {}
    /// Open the window picker and record the chosen window.
    var recordWindow: () -> Void = {}
    var recordFullScreen: () -> Void = {}
    var cancelArmed: () -> Void = {}
    var pauseResume: () -> Void = {}
    var setStageSink: ((@Sendable (PixelBufferBox) -> Void)?) -> Void = { _ in }
    var recordingFrameSize: () -> CGSize = { .zero }
    /// The armed window's still frame for the stage. nil when nothing is armed.
    var armedStageFrame: () async -> ArmedStageFrame? = { nil }
    var revealRecording: (URL) -> Void = { _ in }
    var openRecording: (URL) -> Void = { _ in }
    /// Reveal the newest saved screenshot in Finder.
    var revealScreenshot: (URL) -> Void = { _ in }
    var openSettings: () -> Void = {}
    var openMainWindow: () -> Void = {}
    var reportError: (String) -> Void = { _ in }
    func perform(_ kind: CaptureKind) {
        switch kind {
        case .region: captureRegion()
        case .window: captureWindow()
        case .screen: captureScreen()
        case .scroll: captureScroll()
        case .text: captureText()
        }
    }

}

struct StageView: View {
    let state: RecordingController.UIState
    let isArmed: Bool
    let setSink: ((@Sendable (PixelBufferBox) -> Void)?) -> Void
    let recordingFrameSize: () -> CGSize
    let armedStageFrame: () async -> ArmedStageFrame?

    /// What a press on the canvas started: the placement it began from, and whether it
    /// landed on the rectangle at all (a press on the recording itself moves nothing).
    private struct Drag {
        let options: CameraOptions
        let rect: CGRect
        let frameSize: CGSize
        let corner: CameraCorner?
        let movesCamera: Bool
    }

    private static let space = "recording-stage"
    /// The viewport's shape before a frame has arrived to give it one.
    private static let restingAspect: CGFloat = 16.0 / 9.0
    /// Retina: the composite is rendered at twice the canvas points so the stage is sharp
    /// rather than an upscaled thumbnail — capped, because nothing here needs 4K.
    private static let maximumRenderWidth: CGFloat = 960

    @State private var image: NSImage?
    @State private var thumbnailPixelSize = CGSize.zero
    @State private var frameSize = CGSize.zero
    @State private var options = CameraOptions()
    @State private var rendering = false
    @State private var generation: UInt64 = 0
    @State private var canvasWidth: CGFloat = 0
    @State private var drag: Drag?
    @State private var pointer: PointerStyle?
    @Environment(\.camcordDesignPreview) private var designPreview

    private var isLive: Bool { !isArmed && state != .idle }

    private var sourceKey: String { Self.sourceKey(isArmed: isArmed, state: state) }

    /// What the stage is SHOWING, as the key that re-runs its source task. Pausing is not
    /// such a change: no frame arrives while paused, so tearing the source down there would
    /// blank the stage for the whole pause and leave the veil nothing to sit on. Pure, so
    /// that rule is pinned rather than re-derived from the enum's description.
    static func sourceKey(isArmed: Bool, state: RecordingController.UIState) -> String {
        if isArmed { return "armed" }
        return state == .idle ? "idle" : "live"
    }

    private var aspect: CGFloat {
        guard thumbnailPixelSize.width > 0, thumbnailPixelSize.height > 0 else { return Self.restingAspect }
        return thumbnailPixelSize.width / thumbnailPixelSize.height
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("Sahne")
                    .font(.system(size: 11, weight: .semibold))
                Text("Konum ve boyut tüm hedeflerde ortaktır.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }

            GeometryReader { geometry in
                let bounds = CGRect(origin: .zero, size: geometry.size)
                let thumbnail = Self.thumbnailRect(for: thumbnailPixelSize, in: bounds)

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: CamcordStyle.Radius.control, style: .continuous)
                        .fill(.black.opacity(0.28))

                    if let image, !thumbnail.isEmpty {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: thumbnail.width, height: thumbnail.height)
                            .clipShape(RoundedRectangle(cornerRadius: CamcordStyle.Radius.control, style: .continuous))
                            .position(x: thumbnail.midX, y: thumbnail.midY)

                        if state == .paused {
                            RoundedRectangle(cornerRadius: CamcordStyle.Radius.control, style: .continuous)
                                .fill(.black.opacity(0.46))
                                .frame(width: thumbnail.width, height: thumbnail.height)
                                .overlay {
                                    Text("duraklatıldı")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.9))
                                }
                                .position(x: thumbnail.midX, y: thumbnail.midY)
                        }

                        cameraOverlay(in: thumbnail)
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "rectangle.on.rectangle")
                                .font(.system(size: 18, weight: .light))
                            Text(emptyMessage)
                                .font(.system(size: 10))
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .coordinateSpace(name: Self.space)
                // The canvas — which never moves — owns the gesture and the hit area.
                .contentShape(Rectangle())
                .gesture(stageDrag(thumbnail: thumbnail))
                .onContinuousHover(coordinateSpace: .named(Self.space)) { phase in
                    guard drag == nil else { return }
                    switch phase {
                    case .active(let location):
                        pointer = StageGrip.cursor(for: Self.hit(at: location, options: options,
                                                                 frameSize: frameSize, thumbnail: thumbnail))?.style
                    case .ended:
                        pointer = nil
                    }
                }
                .pointerStyle(drag.map { $0.corner == nil && $0.movesCamera ? .grabActive : pointer } ?? pointer)
                .clipShape(RoundedRectangle(cornerRadius: CamcordStyle.Radius.control, style: .continuous))
                .onAppear { canvasWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { _, width in canvasWidth = width }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
        }
        .task(id: sourceKey) { await activateSource() }
        // The armed stage has no frame feed to refresh it, so the camera switch and a drag
        // on the tile itself would otherwise never reach the rectangle drawn here.
        .onReceive(NotificationCenter.default.publisher(for: RecordingSettings.didChangeNotification)) { _ in
            guard !designPreview, drag == nil else { return }
            options = RecordingSettings.load(from: .standard).camera.resolved()
        }
        .onDisappear(perform: deactivate)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Kayıt sahnesi")
    }

    private var emptyMessage: String {
        if isArmed { return "Pencere görüntüsü alınıyor…" }
        if isLive { return "Kayıt görüntüsü bekleniyor…" }
        return "Kayıt başlayınca burada görünür"
    }

    /// Purely drawn: the rectangle never takes the press that moves it.
    @ViewBuilder
    private func cameraOverlay(in thumbnail: CGRect) -> some View {
        let rect = options.enabled ? Self.cameraRect(options: options, frameSize: frameSize, thumbnail: thumbnail) : .zero
        if !rect.isEmpty {
            let local = CGRect(origin: .zero, size: rect.size)
            ZStack {
                RoundedRectangle(cornerRadius: max(3, CameraOptions.cornerRadius(for: rect.size)))
                    .inset(by: StageGrip.strokeWidth / 2)
                    .stroke(CamcordStyle.accent, lineWidth: StageGrip.strokeWidth)
                ForEach(CameraCorner.allCases.indices, id: \.self) { index in
                    StageGrip.arc(CameraCorner.allCases[index], in: local.insetBy(dx: 2, dy: 2))
                        .stroke(CamcordStyle.accent, style: StrokeStyle(lineWidth: StageGrip.strokeWidth, lineCap: .round))
                }
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
            .accessibilityLabel("Kamera konumu")
            .accessibilityHint("Taşımak için sürükle; köşelerden sürükleyerek boyutlandır")
        }
    }

    // MARK: - Drag

    private func stageDrag(thumbnail: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let started = drag ?? beginDrag(at: value.startLocation, thumbnail: thumbnail)
                drag = started
                guard started.movesCamera else { return }
                updatePlacement(started, translation: value.translation, thumbnail: thumbnail, persists: false)
            }
            .onEnded { value in
                let started = drag ?? beginDrag(at: value.startLocation, thumbnail: thumbnail)
                if started.movesCamera {
                    updatePlacement(started, translation: value.translation, thumbnail: thumbnail, persists: true)
                }
                drag = nil
            }
    }

    private func beginDrag(at start: CGPoint, thumbnail: CGRect) -> Drag {
        let hit = Self.hit(at: start, options: options, frameSize: frameSize, thumbnail: thumbnail)
        return Drag(
            options: options,
            rect: options.rect(in: frameSize),
            frameSize: frameSize,
            corner: hit.corner,
            movesCamera: hit.movesCamera
        )
    }

    /// Where a press on the stage landed, in the recording's own terms: which resize
    /// corner it caught, and whether it touched the camera rectangle at all. Pure, so the
    /// rule that a press on the recording itself moves nothing is testable without a
    /// window.
    static func hit(at start: CGPoint, options: CameraOptions, frameSize: CGSize, thumbnail: CGRect) -> StageHit {
        guard options.enabled, frameSize.width > 0, frameSize.height > 0, !thumbnail.isEmpty else {
            return StageHit(corner: nil, movesCamera: false)
        }
        let scaled = yUpThumbnailRect(options.rect(in: frameSize), frameSize: frameSize, thumbnail: thumbnail)
        let point = CGPoint(
            x: start.x - thumbnail.minX,
            y: thumbnail.height - (start.y - thumbnail.minY)
        )
        let corner = StageGrip.corner(at: point, in: scaled)
        return StageHit(corner: corner, movesCamera: scaled.contains(point))
    }

    private func updatePlacement(_ start: Drag, translation: CGSize, thumbnail: CGRect, persists: Bool) {
        guard start.frameSize.width > 0, start.frameSize.height > 0 else { return }
        let delta = Self.recordingTranslation(
            translation,
            frameSize: start.frameSize,
            thumbnail: thumbnail
        )
        var updated: CameraOptions
        if let corner = start.corner {
            updated = CameraResizeGeometry.resize(
                start: start.rect,
                translation: delta,
                corner: corner,
                options: start.options,
                in: start.frameSize
            )
        } else {
            updated = start.options
            updated.place(
                start.rect.offsetBy(dx: delta.x, dy: delta.y),
                in: start.frameSize,
                snapDistance: min(84, min(start.frameSize.width, start.frameSize.height) * 0.18)
            )
        }
        options = updated.resolved()
        CameraOverlayController.shared.applyPlacement(options, source: .stage, persists: persists)
    }

    // MARK: - Source

    private func activateSource() async {
        generation &+= 1
        let token = generation
        setSink(nil)
        rendering = false
        drag = nil
        image = nil
        thumbnailPixelSize = .zero
        frameSize = .zero
        options = RecordingSettings.load(from: .standard).camera.resolved()

        if isArmed {
            // One retry: the window can be mid-move or the capture can fail transiently, and
            // a stage stuck on "alınıyor…" for the whole arm is worse than a second attempt.
            var armed = await armedStageFrame()
            if armed == nil, token == generation {
                try? await Task.sleep(for: .milliseconds(400))
                armed = await armedStageFrame()
            }
            guard let armed, token == generation else { return }
            let pixelSize = CGSize(width: armed.image.width, height: armed.image.height)
            image = NSImage(cgImage: armed.image, size: pixelSize)
            thumbnailPixelSize = pixelSize
            frameSize = armed.frameSize
        } else if isLive {
            installSink(token: token)
        }
    }

    private func installSink(token: UInt64) {
        setSink { box in
            Task { @MainActor in
                guard token == generation, !rendering else { return }
                let points = recordingFrameSize()
                guard points.width > 0, points.height > 0 else { return }
                rendering = true
                defer { rendering = false }
                let rendered = await CameraPreviewMonitor.shared.renderer.render(
                    box.value, maximumWidth: Self.renderWidth(canvasPoints: canvasWidth)
                )
                guard token == generation, let rendered else { return }
                image = NSImage(cgImage: rendered.image, size: rendered.size)
                thumbnailPixelSize = box.pixelSize
                frameSize = points
                if drag == nil {
                    options = RecordingSettings.load(from: .standard).camera.resolved()
                }
            }
        }
    }

    private func deactivate() {
        // A drag interrupted by the panel closing still meant it: persist what it reached
        // rather than losing the placement to a missing end event.
        if drag?.movesCamera == true {
            CameraOverlayController.shared.applyPlacement(options, source: .stage, persists: true)
        }
        generation &+= 1
        setSink(nil)
        rendering = false
        drag = nil
        image = nil
        thumbnailPixelSize = .zero
        frameSize = .zero
    }

    /// Twice the canvas's points, so a Retina panel is shown the composite rather than an
    /// upscale of it; floored so a canvas that has not been measured yet still gets a usable
    /// image, and capped because a 248 pt viewport has no use for 4K.
    static func renderWidth(canvasPoints: CGFloat) -> CGFloat {
        min(maximumRenderWidth, max(320, canvasPoints * 2))
    }

    /// Aspect-fits the actual recording pixels into the panel canvas.
    static func thumbnailRect(for pixelSize: CGSize, in bounds: CGRect) -> CGRect {
        guard pixelSize.width > 0, pixelSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / pixelSize.width, bounds.height / pixelSize.height)
        let size = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Maps the y-up recording rectangle into SwiftUI's y-down thumbnail coordinates.
    static func cameraRect(options: CameraOptions, frameSize: CGSize, thumbnail: CGRect) -> CGRect {
        guard frameSize.width > 0, frameSize.height > 0, !thumbnail.isEmpty else { return .zero }
        let rect = options.rect(in: frameSize)
        let scale = thumbnail.width / frameSize.width
        return CGRect(
            x: thumbnail.minX + rect.minX * scale,
            y: thumbnail.minY + (frameSize.height - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }

    static func recordingTranslation(_ translation: CGSize, frameSize: CGSize, thumbnail: CGRect) -> CGPoint {
        guard frameSize.width > 0, thumbnail.width > 0 else { return .zero }
        let scale = thumbnail.width / frameSize.width
        return CGPoint(x: translation.width / scale, y: -translation.height / scale)
    }

    static func yUpThumbnailRect(_ rect: CGRect, frameSize: CGSize, thumbnail: CGRect) -> CGRect {
        guard frameSize.width > 0 else { return .zero }
        let scale = thumbnail.width / frameSize.width
        return CGRect(x: rect.minX * scale, y: rect.minY * scale,
                      width: rect.width * scale, height: rect.height * scale)
    }
}


