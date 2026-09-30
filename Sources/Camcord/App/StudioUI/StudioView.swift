import AppKit
import SwiftUI

struct StudioView: View {
    @Environment(\.studioSession) private var session
    @Environment(\.studioSelectRegionAction) private var environmentRegionAction
    @Environment(\.studioClipboardClaim) private var environmentClipboardClaim
    @Environment(\.mainWindowModel) private var mainWindowModel
    @Environment(\.mainWindowLifecycle) private var lifecycle
    @Environment(\.appServices) private var services
    private let selectRegion: (@MainActor () async -> Void)?
    private let claimClipboard: StudioFileActions.Claim?
    @State private var mounted = false

    init(selectRegion: (@MainActor () async -> Void)? = nil, claimClipboard: StudioFileActions.Claim? = nil) {
        self.selectRegion = selectRegion
        self.claimClipboard = claimClipboard
    }
    private var gate: StudioViewGate {
        StudioViewGate(moduleVisible: mounted && mainWindowModel?.selection == .studio,
                       windowAllowsPreview: lifecycle?.allowsLivePreview == true,
                       captureTransition: services?.coordinator.captureTransition.isActive == true)
    }
    var body: some View {
        Group {
            if let session {
                StudioControlRoom(session: session, state: session.recordingState, allowsPreview: gate.allowsPreview,
                                  selectRegion: selectRegion ?? environmentRegionAction,
                                  claimClipboard: claimClipboard ?? environmentClipboardClaim)
            } else {
                ContentUnavailableView {
                    Label("Studio unavailable", systemImage: "video.slash")
                } description: {
                    Text("Recording services are unavailable. Reopen Camcord to try again.")
                }
            }
        }
        .alert("Source selection failed", isPresented: Binding(get: { services?.studioPicker.issue != nil }, set: { if !$0 { services?.studioPicker.dismissIssue() } })) {
            Button("OK") { services?.studioPicker.dismissIssue() }
        } message: {
            if let issue = services?.studioPicker.issue { Text(issue.studioMessage) }
        }
        .onAppear { mounted = true; applyGate() }
        .onChange(of: gate) { _, _ in applyGate() }
        .onDisappear {
            mounted = false
            session?.setVisibility(moduleVisible: false, windowAllowsPreview: false, captureTransition: false)
        }
    }
    private func applyGate() {
        guard let session else { return }
        session.setVisibility(moduleVisible: gate.moduleVisible, windowAllowsPreview: gate.windowAllowsPreview,
                              captureTransition: gate.captureTransition)
        if gate.allowsPreview { Task { await session.refreshSources() } }
    }
}

extension EnvironmentValues {
    @Entry var studioSelectRegionAction: (@MainActor () async -> Void)?
    @Entry var studioClipboardClaim: StudioFileActions.Claim?
}

private struct StudioControlRoom: View {
    let session: StudioSession
    @ObservedObject var state: RecordingStateModel
    let allowsPreview: Bool
    let selectRegion: (@MainActor () async -> Void)?
    let claimClipboard: StudioFileActions.Claim?
    @State private var fileActions = StudioFileActions()
    @State private var showFinished = true
    @State private var sharePresented = false
    private var policy: StudioEditingPolicy {
        StudioEditingPolicy(state: state.state, isStarting: state.isStarting, isFinishing: state.isFinishing,
                            isArmed: state.isArmed, controllerBusy: session.isBusy, allowsPreview: allowsPreview)
    }
    private var locked: Bool { policy.bindingsLocked }
    private var active: Bool { state.state != .idle }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    sourceBar
                    if let issue = session.issue { issueBanner(issue) }
                    StudioStageView(session: session, canEdit: !policy.liveEditsLocked)
                    sourceFacts
                    if showFinished, let url = state.finishedURL, !active, !state.isStarting, !state.isFinishing {
                        finished(url)
                    }
                    transport
                }
                .padding(proxy.size.width < 820 ? 16 : 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                StudioInspector(session: session, state: state, allowsPreview: allowsPreview)
                    .frame(width: proxy.size.width < 850 ? 276 : 312)
            }
        }
        .foregroundStyle(Theme.Palette.ink.color)
        .onChange(of: state.finishedURL) { _, url in showFinished = url != nil; fileActions.cancel() }
        .onChange(of: fileActions.shareURL) { _, url in sharePresented = url != nil }
        .onDisappear { fileActions.cancel() }
        .onChange(of: allowsPreview) { _, visible in if !visible { fileActions.cancel() } }
        .popover(isPresented: $sharePresented) {
            if let url = fileActions.shareURL {
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: url.lastPathComponent).font(Theme.Font.bodyStrong).lineLimit(2)
                    ShareLink(item: url) { Label("Share recording", systemImage: "square.and.arrow.up") }
                }.padding(20).frame(maxWidth: 300)
            }
        }
        .alert("Recording action failed", isPresented: Binding(get: { fileActions.issue != nil }, set: { if !$0 { fileActions.dismissIssue() } })) {
            Button("OK") { fileActions.dismissIssue() }
        } message: { if let issue = fileActions.issue { Text(issue) } }
    }
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Studio").font(Theme.Font.display).tracking(Theme.Font.displayTracking)
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(active ? Theme.Palette.record.color : Theme.Palette.ink3.color).frame(width: 6, height: 6)
                Text(status).font(Theme.Font.captionStrong).foregroundStyle(Theme.Palette.ink2.color)
            }.accessibilityElement(children: .combine)
        }
    }
    private var status: LocalizedStringResource {
        if state.isFinishing { return "Finalizing…" }
        if state.isStarting { return "Starting…" }
        if state.isArmed { return "Ready to record" }
        if state.state == .paused { return "Paused" }
        if active { return "Recording" }
        return "Set up your recording"
    }
    private var sourceBar: some View {
        HStack(spacing: 10) {
            Menu {
                Section("Screens") {
                    ForEach(session.sources.filter { if case .display = $0.id { true } else { false } }) { source in
                        sourceButton(source, symbol: "display")
                    }
                }
                Section("Windows") {
                    ForEach(session.sources.filter { if case .window = $0.id { true } else { false } }) { source in
                        sourceButton(source, symbol: "macwindow")
                    }
                }
                if let selectRegion { Button("Choose a region…", systemImage: "crop") { Task { await selectRegion() } } }
                Divider()
                Button("Clear source", systemImage: "xmark") { session.clearSource() }.disabled(session.selectedSource == nil)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: sourceSymbol)
                    Text(verbatim: session.selectedSource?.title ?? String(localized: "Choose a source"))
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
            .menuStyle(.borderlessButton).padding(10)
            .camcordGlass(.chromeInteractive, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .disabled(locked)
            .accessibilityLabel(Text("Recording source"))
            Button { Task { await session.refreshSources() } } label: {
                if session.isRefreshingSources { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise") }
            }.buttonStyle(.bordered).disabled(locked || !allowsPreview || session.isRefreshingSources)
                .help(Text("Refresh sources")).accessibilityLabel(Text("Refresh sources"))
        }
    }
    private func sourceButton(_ source: StudioSourceChoice, symbol: String) -> some View {
        Button { session.selectSource(source) } label: {
            Label { Text(verbatim: "\(source.title) · \(Int(source.pixelSize.width))×\(Int(source.pixelSize.height))") } icon: {
                Image(systemName: source.id == session.selectedSource?.id ? "checkmark" : symbol)
            }
        }
    }
    private var sourceSymbol: String {
        switch session.selectedSource?.id {
        case .display: "display"
        case .window: "macwindow"
        case .region: "crop"
        case nil: "rectangle.dashed"
        }
    }
    private var sourceFacts: some View {
        HStack(spacing: 12) {
            if let source = session.selectedSource {
                Text(verbatim: "\(Int(source.pixelSize.width))×\(Int(source.pixelSize.height))").font(Theme.Font.data)
                Text(verbatim: "\(session.settings.fps) fps · \(RecordingSettingsPage.codecTitle(session.settings.resolvedCodec)) · \(session.settings.effectiveContainer.rawValue.uppercased())").font(Theme.Font.dataSmall).lineLimit(1)
                Spacer(minLength: 0)
                Text("Preview").font(Theme.Font.caption)
            } else {
                Text("No source selected").font(Theme.Font.caption)
                Spacer()
            }
        }.foregroundStyle(Theme.Palette.ink3.color)
    }
    private func issueBanner(_ issue: StudioIssue) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.Palette.warn.color)
            Text(issue.studioMessage).font(Theme.Font.caption).frame(maxWidth: .infinity, alignment: .leading)
            if issue == .screenPermissionRequired {
                Button("Settings") { NSWorkspace.shared.open(PermissionRecovery.screenRecordingPaneURL) }.controlSize(.small)
            }
            Button { session.dismissIssue() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(Text("Dismiss"))
        }.padding(10).background(Theme.Palette.surface.color, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
    }
    private var transport: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: state.elapsed ?? "00:00").font(Theme.Font.timecode)
                Text(status).font(Theme.Font.caption).foregroundStyle(Theme.Palette.ink3.color)
            }
            Spacer(minLength: 4)
            if active {
                Button { session.pauseResume() } label: {
                    Label { Text(state.state == .paused ? LocalizedStringResource("Resume") : LocalizedStringResource("Pause")) } icon: {
                        Image(systemName: state.state == .paused ? "play.fill" : "pause.fill")
                    }
                }.buttonStyle(.bordered).disabled(state.isFinishing || state.isStarting)
                Button { Task { await session.stopRecording() } } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(.borderedProminent).tint(Theme.Palette.record.color).disabled(state.isFinishing)
                    .keyboardShortcut(".", modifiers: [.command, .shift])
            } else {
                Button { showFinished = false; Task { await session.startRecording() } } label: {
                    HStack(spacing: 8) {
                        if state.isStarting || state.isFinishing { ProgressView().controlSize(.small) }
                        else { Image(systemName: "record.circle.fill") }
                        Text("Record").font(Theme.Font.bodyStrong)
                    }.frame(minWidth: 102, minHeight: 30)
                }.buttonStyle(.borderedProminent).tint(Theme.Palette.record.color)
                    .disabled(!session.canStart || !allowsPreview || state.isArmed || state.isStarting || state.isFinishing)
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }.padding(.top, 4)
    }
    private func finished(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Recording saved", systemImage: "checkmark.circle").font(Theme.Font.bodyStrong)
                Spacer()
                Button { showFinished = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(Text("Dismiss"))
            }
            Text(verbatim: url.lastPathComponent).font(Theme.Font.caption).foregroundStyle(Theme.Palette.ink2.color).lineLimit(1).textSelection(.enabled)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { finishedActions(url) }
                VStack(alignment: .leading, spacing: 8) { finishedActions(url) }
            }.controlSize(.small)
        }.padding(14).background(Theme.Palette.surface.color, in: RoundedRectangle(cornerRadius: Theme.Radius.box))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.box).strokeBorder(Theme.Palette.hairline.color))
    }
    @ViewBuilder private func finishedActions(_ url: URL) -> some View {
        Button("Open") { Task { await fileActions.perform(.open, url: url) } }
        Button("Copy file") { Task { await fileActions.perform(.copy, url: url, claimClipboard: claimClipboard) } }
        Button("Share") { Task { await fileActions.perform(.share, url: url) } }
        Button("Reveal") { Task { await fileActions.perform(.reveal, url: url) } }
        Button("Record again") { showFinished = false; Task { await session.startRecording() } }.disabled(!session.canStart || !allowsPreview)
    }
}
