import SwiftUI

struct StudioStageView: View {
    let session: StudioSession
    let canEdit: Bool
    @State private var layerDragStart: CGRect?
    @State private var cameraDragStart: CameraOptions?
    @State private var cameraResizeCorner: CameraCorner?
    @State private var editCamera = false

    var body: some View {
        GeometryReader { proxy in
            let fitted = StudioStageGeometry.fittedCanvas(session.canvasSize, in: CGRect(origin: .zero, size: proxy.size))
            ZStack(alignment: .topLeading) {
                Theme.Palette.well.color
                if let image = session.stageImage {
                    Image(nsImage: image).resizable().interpolation(.high)
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)
                        .accessibilityLabel(Text("Recording preview"))
                    if canEdit, let layer = selectedLayer, layer.isVisible {
                        layerOutline(layer, fitted: fitted)
                    }
                    if canEdit, editCamera, session.settings.camera.enabled {
                        cameraOutline(fitted: fitted)
                    }
                } else {
                    placeholder.frame(width: proxy.size.width, height: proxy.size.height)
                }
                VStack {
                    Spacer()
                    HStack {
                        if session.settings.camera.enabled, canEdit {
                            Button { editCamera.toggle(); session.layers.selectedID = nil } label: {
                                Label("Place camera", systemImage: "viewfinder")
                            }
                            .buttonStyle(.bordered)
                            .tint(.white)
                            .disabled(session.stageImage == nil)
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
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.box).strokeBorder(Theme.Palette.hairlineStrong.color))
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
            if session.previewState == .starting { ProgressView().controlSize(.regular) }
            else { Image(systemName: session.previewState == .permissionRequired ? "lock.shield" : "viewfinder").font(.system(size: 34, weight: .light)) }
            Text(placeholderTitle).font(Theme.Font.bodyStrong)
            Text(placeholderDetail).font(Theme.Font.caption).multilineTextAlignment(.center).frame(maxWidth: 280)
            if session.previewState == .permissionRequired || session.previewState == .unavailable {
                Button("Retry preview") { Task { await session.retryPreview() } }.buttonStyle(.bordered)
            }
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(24)
    }
    private var placeholderTitle: LocalizedStringResource {
        switch session.previewState {
        case .inactive: "Preview paused"
        case .noSource: "Choose a source"
        case .starting: "Starting preview…"
        case .permissionRequired: "Screen Recording permission required"
        case .unavailable: "Preview unavailable"
        case .live, .recording, .paused: "Waiting for a frame…"
        }
    }
    private var placeholderDetail: LocalizedStringResource {
        switch session.previewState {
        case .inactive: "The preview runs while Studio is visible."
        case .noSource: "Select a screen, window or region to set up your recording."
        case .permissionRequired: "Allow Screen Recording in System Settings, then retry."
        case .unavailable: "Refresh your sources or choose another source."
        default: "Your source, camera and layers appear here as they will be recorded."
        }
    }
}
