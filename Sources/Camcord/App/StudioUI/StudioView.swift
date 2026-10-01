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
    private var finishedURL: URL? {
        showFinished && state.state == .idle && !state.isStarting && !state.isFinishing ? state.finishedURL : nil
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Studio.mainSpacing) {
                StudioHeading(session: session, state: state, locked: policy.bindingsLocked)
                if state.state != .idle {
                    StudioRecordingTransport(session: session, state: state)
                } else {
                    StudioSourceStrip(session: session, locked: policy.bindingsLocked, selectRegion: selectRegion)
                }
                if let issue = session.issue { StudioIssueBanner(session: session, issue: issue) }
                if let url = finishedURL {
                    StudioCompletedCard(url: url, fileActions: fileActions, claimClipboard: claimClipboard)
                    Spacer(minLength: 0)
                } else {
                    StudioStageView(session: session, canEdit: !policy.liveEditsLocked)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            StudioInspector(session: session, state: state, allowsPreview: allowsPreview,
                            completed: finishedURL != nil, record: record)
                .frame(width: Theme.Studio.inspectorWidth)
        }
        .foregroundStyle(Theme.Palette.ink.color)
        .onChange(of: state.finishedURL) { _, url in showFinished = url != nil; fileActions.cancel() }
        .onChange(of: fileActions.shareURL) { _, url in sharePresented = url != nil }
        .onDisappear { fileActions.cancel() }
        .onChange(of: allowsPreview) { _, visible in if !visible { fileActions.cancel() } }
        .popover(isPresented: $sharePresented) {
            if let url = fileActions.shareURL {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Text(verbatim: url.lastPathComponent).font(Theme.Font.bodyStrong).lineLimit(2)
                    ShareLink(item: url) { Label("Share recording", systemImage: "square.and.arrow.up") }
                }.padding(Theme.Studio.sideInset).frame(maxWidth: 300)
            }
        }
        .alert("Recording action failed", isPresented: Binding(get: { fileActions.issue != nil }, set: { if !$0 { fileActions.dismissIssue() } })) {
            Button("OK") { fileActions.dismissIssue() }
        } message: { if let issue = fileActions.issue { Text(issue) } }
    }

    private func record() {
        showFinished = false
        Task { await session.startRecording() }
    }
}

private struct StudioHeading: View {
    let session: StudioSession
    @ObservedObject var state: RecordingStateModel
    let locked: Bool
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text("Studio").font(Theme.Font.display).tracking(Theme.Font.displayTracking)
            Text(status).font(Theme.Font.data).foregroundStyle(Theme.Palette.ink3.color)
            Spacer(minLength: 0)
            if state.state == .idle {
                Button { Task { await session.refreshSources() } } label: {
                    if session.isRefreshingSources { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.plain).foregroundStyle(Theme.Palette.ink3.color)
                .help(Text("Refresh sources")).accessibilityLabel(Text("Refresh sources"))
                .disabled(locked || session.isRefreshingSources)
            }
        }
    }
    private var status: LocalizedStringResource {
        if state.isFinishing { return "Finalizing…" }
        if state.isStarting { return "Starting…" }
        if state.isArmed { return "Ready to record" }
        if state.state == .paused { return "Paused" }
        if state.state != .idle { return "Recording" }
        return "Set up your recording"
    }
}

private struct StudioIssueBanner: View {
    let session: StudioSession
    let issue: StudioIssue
    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.Palette.warn.color)
            Text(issue.studioMessage).font(Theme.Font.caption).frame(maxWidth: .infinity, alignment: .leading)
            if issue == .screenPermissionRequired {
                Button("Settings", action: openPermissions).controlSize(.small)
            }
            Button(action: session.dismissIssue) { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel(Text("Dismiss"))
        }
        .padding(Theme.Space.m)
        .background(Theme.Palette.surface.color, in: .rect(cornerRadius: Theme.Radius.control))
    }
    private func openPermissions() { NSWorkspace.shared.open(PermissionRecovery.screenRecordingPaneURL) }
}

private struct StudioRecordingTransport: View {
    let session: StudioSession
    @ObservedObject var state: RecordingStateModel
    var body: some View {
        HStack(spacing: Theme.Space.l) {
            Circle().strokeBorder(Theme.Palette.record.color, lineWidth: 2)
                .overlay { if state.state != .paused { Circle().fill(Theme.Palette.record.color).padding(Theme.Space.s) } }
                .frame(width: Theme.Studio.channelIcon, height: Theme.Studio.channelIcon)
                .accessibilityHidden(true)
            if let elapsed = state.elapsed { Text(verbatim: elapsed).font(Theme.Font.timecode) }
            if let source = session.selectedSource {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(verbatim: source.title).lineLimit(1)
                }.font(Theme.Font.dataSmall).foregroundStyle(Theme.Palette.ink3.color)
            }
            Spacer(minLength: 0)
            Button(action: session.pauseResume) {
                Label { Text(state.state == .paused ? LocalizedStringResource("Resume") : LocalizedStringResource("Pause")) }
                    icon: { Image(systemName: state.state == .paused ? "play.fill" : "pause.fill") }
            }.buttonStyle(.bordered).disabled(state.isFinishing || state.isStarting)
            Button(action: stop) { Label("Stop", systemImage: "stop.fill") }
                .buttonStyle(.borderedProminent).tint(Theme.Palette.record.color).disabled(state.isFinishing)
                .keyboardShortcut(".", modifiers: [.command, .shift])
        }
    }
    private func stop() { Task { await session.stopRecording() } }
}

/// File facts are deliberately limited to the verified finished URL. Reading media
/// metadata may be added only through a bounded real-file reader; no setup values are facts.
private struct StudioCompletedCard: View {
    let url: URL
    let fileActions: StudioFileActions
    let claimClipboard: StudioFileActions.Claim?
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Label("Recording saved", systemImage: "checkmark.circle")
                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.ok.color)
            Text(verbatim: url.lastPathComponent).font(Theme.Font.title).lineLimit(2).textSelection(.enabled)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.s) { actions }
                VStack(alignment: .leading, spacing: Theme.Space.s) { actions }
            }.controlSize(.small)
        }
        .padding(Theme.Space.l).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface.color, in: .rect(cornerRadius: Theme.Radius.box))
        .overlay { RoundedRectangle(cornerRadius: Theme.Radius.box).strokeBorder(Theme.Palette.hairline.color) }
    }
    @ViewBuilder private var actions: some View {
        Button("Open") { perform(.open) }
        Button("Copy file") { perform(.copy) }
        Button("Share") { perform(.share) }
        Button("Reveal") { perform(.reveal) }
    }
    private func perform(_ action: StudioFileActions.Action) {
        Task { await fileActions.perform(action, url: url, claimClipboard: claimClipboard) }
    }
}
