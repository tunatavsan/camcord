import SwiftUI

struct StudioStageView: View {
    let session: StudioSession
    let canEdit: Bool
    @Environment(\.studioPresentationProvider) private var provider
    private var presentation: StudioPresentationSnapshot? { provider?.snapshot }
    private var image: NSImage? { presentation == nil ? session.stageImage : presentation?.stageImage }
    private var canvasSize: CGSize { presentation?.canvasSize ?? session.canvasSize }
    private var previewState: StudioPreviewState { presentation?.previewState ?? session.previewState }
    private var permitsEditing: Bool { presentation == nil && canEdit }
    @State private var layerDragStart: CGRect?
    @State private var cameraDragStart: CameraOptions?
    @State private var cameraResizeCorner: CameraCorner?
    @State private var editCamera = false

    var body: some View {
        GeometryReader { proxy in
            let fitted = StudioStageGeometry.fittedCanvas(canvasSize, in: CGRect(origin: .zero, size: proxy.size))
            ZStack(alignment: .topLeading) {
                Theme.Palette.well.color
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high)
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)
                        .accessibilityLabel(Text("Recording preview"))
                    if permitsEditing, let layer = selectedLayer, layer.isVisible {
                        layerOutline(layer, fitted: fitted)
                    }
                    if permitsEditing, editCamera, session.settings.camera.enabled, session.cameraMonitor.currentPreviewFrame() != nil {
                        cameraOutline(fitted: fitted)
                    }
                } else {
                    placeholder.frame(width: proxy.size.width, height: proxy.size.height)
                }
                if presentation == nil, image != nil, previewState == .live || previewState == .recording || previewState == .paused {
                    HStack(spacing: Theme.Space.s) {
                        Circle().fill(previewState == .live ? Theme.Palette.ok.color : Theme.Palette.record.color).frame(width: Theme.Studio.meterHeight, height: Theme.Studio.meterHeight)
                        Text(verbatim: previewState == .live ? "LIVE" : previewState == .paused ? "PAUSED" : "REC")
                        Text(verbatim: "12 fps preview")
                    }.font(Theme.Font.dataSmall).foregroundStyle(Theme.Palette.onRecord.color).padding(Theme.Space.m)
                }
                VStack {
                    Spacer()
                    HStack {
                        if session.settings.camera.enabled, permitsEditing {
                            Button { editCamera.toggle(); session.layers.selectedID = nil } label: {
                                Label("Place camera", systemImage: "viewfinder")
                            }
                            .buttonStyle(.bordered)
                            .tint(.white)
                            .disabled(session.stageImage == nil || session.cameraMonitor.currentPreviewFrame() == nil)
                            .help(Text("Camera preview is unavailable until a camera frame arrives."))
                        }
                        Spacer()
                    }
                }
                .padding(12)
            }
        }
        .frame(minHeight: 140)
        .coordinateSpace(.named("studio-stage"))
        .clipShape(.rect(cornerRadius: Theme.Radius.box))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.box).strokeBorder(Theme.Palette.hairline.color))
        .onChange(of: session.layers.selectedID) { _, id in if id != nil { editCamera = false } }
    }

    private var selectedLayer: StudioLayer? { session.layers.layers.first { $0.id == session.layers.selectedID } }
    private func layerOutline(_ layer: StudioLayer, fitted: CGRect) -> some View {
        let rect = StudioStageGeometry.layerRect(layer.rect, in: fitted)
        return RoundedRectangle(cornerRadius: 3).strokeBorder(.white, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            .background(.white.opacity(0.001))
            .frame(width: rect.width, height: rect.height)
            .gesture(DragGesture(coordinateSpace: .named("studio-stage")).onChanged { value in
                if layerDragStart == nil { layerDragStart = layer.rect }
                guard let start = layerDragStart else { return }
                session.layers.update(layer.id) { $0.rect = StudioStageGeometry.movedLayer(start, translation: value.translation, canvas: fitted) }
            }.onEnded { _ in layerDragStart = nil })
            .position(x: rect.midX, y: rect.midY)
            .accessibilityLabel(Text("Layer position"))
            .accessibilityHint(Text("Use the inspector to adjust position with the keyboard."))
    }
    private func cameraOutline(fitted: CGRect) -> some View {
        let rect = StudioStageGeometry.cameraRect(session.settings.camera, canvas: session.canvasSize,
                                                  contentRect: session.cameraContentRect, fitted: fitted)
        return RoundedRectangle(cornerRadius: CameraOptions.cornerRadius(for: rect.size)).strokeBorder(.white, lineWidth: 1.5)
            .overlay {
                Canvas { context, size in
                    for corner in CameraCorner.allCases {
                        context.stroke(StageGrip.arc(corner, in: CGRect(origin: .zero, size: size)), with: .color(.white), lineWidth: StageGrip.strokeWidth)
                    }
                }.accessibilityHidden(true)
            }
            .background(.white.opacity(0.001))
            .frame(width: rect.width, height: rect.height)
            .gesture(DragGesture(coordinateSpace: .named("studio-stage")).onChanged { value in
                if cameraDragStart == nil {
                    cameraDragStart = session.settings.camera
                    cameraResizeCorner = StageGrip.corner(at: CGPoint(x: value.startLocation.x - rect.minX, y: value.startLocation.y - rect.minY),
                                                          in: CGRect(origin: .zero, size: rect.size), yDown: true)
                }
                guard let start = cameraDragStart else { return }
                let next: CameraOptions
                if let corner = cameraResizeCorner {
                    next = StudioStageGeometry.resizedCamera(start, translation: value.translation, corner: corner,
                        canvas: session.canvasSize, contentRect: session.cameraContentRect, fitted: fitted)
                } else {
                    next = StudioStageGeometry.movedCamera(start, translation: value.translation, canvas: session.canvasSize,
                        contentRect: session.cameraContentRect, fitted: fitted)
                }
                session.updateSettings { $0.camera.position = next.position; $0.camera.corner = next.corner; $0.camera.widthFraction = next.widthFraction }
            }.onEnded { _ in cameraDragStart = nil; cameraResizeCorner = nil })
            .position(x: rect.midX, y: rect.midY)
            .accessibilityLabel(Text("Camera position"))
            .accessibilityHint(Text("Use the inspector to adjust position with the keyboard."))
    }
    private var placeholder: some View {
        VStack(spacing: Theme.Space.m) {
            if previewState == .starting { ProgressView().controlSize(.regular) }
            else { Image(systemName: previewState == .permissionRequired ? "lock.shield" : "viewfinder").font(Theme.Studio.placeholderSymbol) }
            Text(placeholderTitle).font(Theme.Font.bodyStrong)
            Text(placeholderDetail).font(Theme.Font.caption).multilineTextAlignment(.center).frame(maxWidth: 280)
            if previewState == .permissionRequired {
                Button("Open System Settings…") {
                    if presentation == nil { NSWorkspace.shared.open(PermissionRecovery.screenRecordingPaneURL) }
                }.buttonStyle(.borderedProminent).tint(Theme.Palette.record.color)
            } else if previewState == .unavailable {
                Button("Retry preview") { if presentation == nil { Task { await session.retryPreview() } } }.buttonStyle(.bordered)
            }
        }
        .foregroundStyle(Theme.Palette.onRecord.color)
        .padding(Theme.Space.xl)
    }
    private var placeholderTitle: LocalizedStringResource {
        switch previewState {
        case .inactive: "Preview paused"
        case .noSource: "Choose a source"
        case .starting: "Starting preview…"
        case .permissionRequired: "Screen Recording permission required"
        case .unavailable: "Preview unavailable"
        case .live, .recording, .paused: "Waiting for a frame…"
        }
    }
    private var placeholderDetail: LocalizedStringResource {
        switch previewState {
        case .inactive: "The preview runs while Studio is visible."
        case .noSource: "Select a screen, window or region to set up your recording."
        case .permissionRequired: "Camcord needs Screen Recording permission to show a live preview."
        case .unavailable: "Refresh your sources or choose another source."
        default: "Your source, camera and layers appear here as they will be recorded."
        }
    }
}
