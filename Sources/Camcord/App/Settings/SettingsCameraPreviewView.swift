import SwiftUI

/// A Settings-owned display subscription. Capture starts only on the Preview button;
/// recording-owned capture is observed through the monitor and never stopped here.
struct SettingsCameraPreviewView: View {
    let options: CameraOptions
    @ObservedObject private var monitor = CameraPreviewMonitor.shared
    @State private var owner = CameraPreviewMonitor.makeOwnerID("settings")
    @State private var visible = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.Palette.well.color)
                if let image = monitor.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(x: options.resolved().mirrored ? -1 : 1, y: 1)
                } else {
                    VStack(spacing: Theme.Space.s) {
                        Image(systemName: "video").font(Theme.Font.title)
                        Text(status).font(Theme.Font.caption)
                    }
                    .foregroundStyle(Theme.Palette.ink2.color)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 150)
            .clipShape(.rect(cornerRadius: Theme.Radius.control))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Camera preview", comment: "Accessibility: camera preview"))
            .accessibilityValue(Text(status))
            HStack(spacing: Theme.Space.m) {
                Text(status).font(Theme.Font.caption).foregroundStyle(Theme.Palette.ink2.color)
                Spacer(minLength: Theme.Space.s)
                if monitor.recordingLocked {
                    Label { Text("Used by the recording", comment: "Camera preview status") } icon: {
                        Image(systemName: "record.circle")
                    }
                    .font(Theme.Font.caption)
                } else {
                    Button {
                        Task {
                            guard visible else { return }
                            if monitor.isRunning { await monitor.stop() }
                            else {
                                await monitor.start(deviceID: options.resolved().deviceID, format: options.resolved().format,
                                                    requestPermission: true)
                            }
                        }
                    } label: {
                        if monitor.isRunning { Text("Stop preview", comment: "Button: stop the camera preview") }
                        else { Text("Preview", comment: "Button: start the camera preview") }
                    }
                    .disabled(monitor.isStarting)
                }
            }
        }
        .onAppear { visible = true; monitor.setVisible(true, owner: owner) }
        .onDisappear {
            visible = false
            monitor.setVisible(false, owner: owner)
            Task { await monitor.stopIfUnobserved() }
        }
        .onChange(of: options.resolved().deviceID) { _, _ in
            Task { if visible { await monitor.cameraSettingsChanged(options) } }
        }
        .onChange(of: options.resolved().format) { _, _ in
            Task { if visible { await monitor.cameraSettingsChanged(options) } }
        }
    }

    private var status: LocalizedStringResource {
        if monitor.message != nil {
            return LocalizedStringResource("Camera preview failed. Check permission and the selected device.", comment: "Camera preview recovery")
        }
        if monitor.isStarting { return LocalizedStringResource("Starting camera…", comment: "Camera preview status") }
        if monitor.recordingLocked, monitor.image == nil {
            return LocalizedStringResource("Waiting for the recording camera…", comment: "Camera preview status")
        }
        if monitor.isRunning { return LocalizedStringResource("Live preview", comment: "Camera preview status") }
        return LocalizedStringResource("Start a preview to check your camera", comment: "Camera preview status")
    }
}
