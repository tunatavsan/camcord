import AppKit
import SwiftUI

struct StudioView: View {
    @Environment(\.studioPresentationProvider) private var presentationProvider
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
        // A read-only supplied presentation never owns live resource intent.
        guard presentationProvider == nil, let session else { return }
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
    @Environment(\.studioPresentationProvider) private var provider
    private var presentation: StudioPresentationSnapshot? { provider?.snapshot }
    let session: StudioSession
    @ObservedObject var state: RecordingStateModel
    let allowsPreview: Bool
    let selectRegion: (@MainActor () async -> Void)?
    let claimClipboard: StudioFileActions.Claim?
    @State private var fileActions = StudioFileActions()
    @State private var showFinished = true
    @State private var sharePresented = false
    private var displayState: RecordingController.UIState { presentation?.recordingState ?? state.state }
    private var policy: StudioEditingPolicy {
        StudioEditingPolicy(state: state.state, isStarting: state.isStarting, isFinishing: state.isFinishing,
                            isArmed: state.isArmed, controllerBusy: session.isBusy, allowsPreview: allowsPreview)
    }
    private var finishedURL: URL? {
        if let presentation { return presentation.finishedFile?.url }
        return showFinished && state.state == .idle && !state.isStarting && !state.isFinishing ? state.finishedURL : nil
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                StudioHeading(session: session, state: state, locked: policy.bindingsLocked)
                if displayState != .idle {
                    StudioRecordingTransport(session: session, state: state)
                } else {
                    StudioSourceStrip(session: session, locked: presentation == nil && policy.bindingsLocked, selectRegion: selectRegion)
                }
                if presentation == nil, let issue = session.issue { StudioIssueBanner(session: session, issue: issue) }
                if let url = finishedURL {
                    ScrollView(.vertical) {
                        StudioCompletedCard(url: url, fileActions: fileActions, claimClipboard: claimClipboard)
                            .padding(.bottom, Theme.Space.xs)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .scrollBounceBehavior(.basedOnSize)
                } else {
                    StudioStageView(session: session, canEdit: presentation == nil && !policy.liveEditsLocked)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(Theme.Space.l)
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
        guard presentation == nil else { return }
        showFinished = false
        Task { await session.startRecording() }
    }
}

private struct StudioHeading: View {
    @Environment(\.studioPresentationProvider) private var provider
    private var presentation: StudioPresentationSnapshot? { provider?.snapshot }
    let session: StudioSession
    @ObservedObject var state: RecordingStateModel
    let locked: Bool
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text("Studio").font(Theme.Font.display).tracking(Theme.Font.displayTracking)
            Group {
                if let presentation {
                    Text(verbatim: [presentation.selectedSource?.title, presentation.settings.camera.enabled ? presentation.cameraName : nil,
                                    "\(String(localized: "Audio")) \((presentation.settings.systemAudio ? 1 : 0) + (presentation.settings.microphone ? 1 : 0))"].compactMap { $0 }.joined(separator: " · "))
                }
                else if let source = session.selectedSource, state.state == .idle {
                    Text(verbatim: source.title + " · " + String(localized: "Camera") + " " + String(localized: session.settings.camera.enabled ? "On" : "Off") + " · " + String(localized: "Audio") + " \((session.settings.systemAudio ? 1 : 0) + (session.settings.microphone ? 1 : 0))")
                } else { Text(status) }
            }.font(Theme.Font.data).foregroundStyle(Theme.Palette.ink3.color)
            Spacer(minLength: 0)
            if (presentation?.recordingState ?? state.state) == .idle {
                Button { if presentation == nil { Task { await session.refreshSources() } } } label: {
                    if session.isRefreshingSources { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.plain).foregroundStyle(Theme.Palette.ink3.color)
                .help(Text("Refresh sources")).accessibilityLabel(Text("Refresh sources"))
                .disabled(presentation == nil && (locked || session.isRefreshingSources))
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
    @Environment(\.studioPresentationProvider) private var provider
    private var presentation: StudioPresentationSnapshot? { provider?.snapshot }
    let session: StudioSession
    @ObservedObject var state: RecordingStateModel
    private var source: StudioSourceChoice? { presentation == nil ? session.selectedSource : presentation?.selectedSource }
    private var elapsed: String? { presentation == nil ? state.elapsed : presentation?.elapsed }
    private var dimensions: String {
        let size = presentation?.canvasSize ?? session.canvasSize
        return "\(Int(size.width)) × \(Int(size.height)) · \(presentation?.settings.fps ?? session.settings.fps) fps"
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.l) {
                tally
                clock.fixedSize()
                summary.frame(minWidth: Theme.Studio.sourceWidth)
                Spacer(minLength: 0)
                controls.fixedSize()
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    tally
                    clock.frame(maxWidth: .infinity, alignment: .leading)
                    controls.fixedSize()
                }
                if let source {
                    HStack(spacing: Theme.Space.s) {
                        Text(verbatim: source.title).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Text(verbatim: dimensions).fixedSize()
                    }.font(Theme.Font.dataSmall).foregroundStyle(Theme.Palette.ink3.color)
                }
            }
        }
    }
    private var tally: some View {
        Circle().strokeBorder(Theme.Palette.record.color, lineWidth: 2)
            .overlay { if (presentation?.recordingState ?? state.state) != .paused { Circle().fill(Theme.Palette.record.color).padding(Theme.Space.s) } }
            .frame(width: Theme.Studio.channelIcon, height: Theme.Studio.channelIcon).accessibilityHidden(true)
    }
    @ViewBuilder private var clock: some View {
        if let elapsed {
            Text(verbatim: StudioDisplayTime.clock(elapsed)).font(Theme.Font.timecode)
                .lineLimit(1).minimumScaleFactor(0.75).fixedSize(horizontal: false, vertical: true)
        }
    }
    @ViewBuilder private var summary: some View {
        if let source {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(verbatim: source.title).lineLimit(1).truncationMode(.middle)
                Text(verbatim: dimensions).lineLimit(1)
            }.font(Theme.Font.dataSmall).foregroundStyle(Theme.Palette.ink3.color)
        }
    }
    private var controls: some View {
        HStack(spacing: Theme.Space.s) {
            Button { if presentation == nil { session.pauseResume() } } label: {
                Label { Text((presentation?.recordingState ?? state.state) == .paused ? LocalizedStringResource("Resume") : LocalizedStringResource("Pause")) }
                    icon: { Image(systemName: (presentation?.recordingState ?? state.state) == .paused ? "play.fill" : "pause.fill") }
                    .lineLimit(1).fixedSize()
            }.buttonStyle(.bordered).disabled(state.isFinishing || state.isStarting)
            Button(action: stop) {
                Label("Stop", systemImage: "stop.fill").font(Theme.Font.bodyStrong).lineLimit(1).fixedSize()
                    .foregroundStyle(Theme.Palette.onRecord.color).padding(.horizontal, Theme.Space.m)
                    .padding(.vertical, Theme.Space.s)
                    .background(Theme.Palette.record.color, in: .rect(cornerRadius: Theme.Radius.key))
            }.buttonStyle(.plain).disabled(state.isFinishing)
                .keyboardShortcut(".", modifiers: [.command, .shift])
        }
    }
    private func stop() { if presentation == nil { Task { await session.stopRecording() } } }
}

/// File facts come only from the verified finished file, never from setup values.
private struct StudioCompletedCard: View {
    @Environment(\.studioPresentationProvider) private var provider
    private var presentation: StudioPresentationSnapshot? { provider?.snapshot }
    let url: URL
    let fileActions: StudioFileActions
    let claimClipboard: StudioFileActions.Claim?
    @State private var media = StudioFinishedFileState()
    private var file: StudioFinishedFilePresentation? { presentation == nil ? media.file : presentation?.finishedFile }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Theme.Space.l) {
                thumbnail.frame(width: 180, height: 112.5)
                details.frame(minWidth: Theme.Studio.sourceWidth * 1.5)
            }
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                thumbnail.frame(maxWidth: .infinity).frame(height: 112.5)
                details
            }
        }
        .padding(Theme.Space.l).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface.color, in: .rect(cornerRadius: Theme.Radius.box))
        .overlay { RoundedRectangle(cornerRadius: Theme.Radius.box).strokeBorder(Theme.Palette.hairline.color) }
        .task(id: url) { if presentation == nil { await media.load(url) } }
        .onDisappear { media.hide() }
    }
    private var thumbnail: some View {
        ZStack {
            Theme.Palette.well.color
            if let image = file?.thumbnail {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                Image(systemName: "film").font(Theme.Studio.placeholderSymbol).foregroundStyle(Theme.Palette.ink3.color)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let duration = file?.duration {
                Text(verbatim: "▷ " + StudioDisplayTime.length(duration)).font(Theme.Font.dataSmall)
                    .foregroundStyle(Theme.Palette.onRecord.color).padding(Theme.Space.xs)
                    .background(Theme.Palette.well.color, in: .rect(cornerRadius: Theme.Radius.key)).padding(Theme.Space.s)
            }
        }.clipShape(.rect(cornerRadius: Theme.Radius.control))
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(verbatim: url.deletingPathExtension().lastPathComponent).font(Theme.Font.title).lineLimit(2).textSelection(.enabled)
            if file != nil {
                Label("Saved to file", systemImage: "checkmark.circle").font(Theme.Font.caption).foregroundStyle(Theme.Palette.ok.color)
            } else {
                Text(media.isLoading ? LocalizedStringResource("Reading recording…") : LocalizedStringResource("Recording file unavailable"))
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.ink3.color)
            }
            if let file {
                if let duration = file.duration { fact("Length", StudioDisplayTime.length(duration)) }
                if let bytes = file.byteCount { fact("Size", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
                if let size = file.dimensions { fact("Format", "\(url.pathExtension.uppercased()) · \(Int(size.width)) × \(Int(size.height))") }
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) { open; copy }
                HStack(spacing: Theme.Space.s) { share; reveal }
            }.controlSize(.regular).padding(.top, Theme.Space.s)
        }
    }
    private func fact(_ title: LocalizedStringResource, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(Theme.Palette.ink3.color); Spacer(minLength: Theme.Space.s); Text(verbatim: value).multilineTextAlignment(.trailing) }
            .font(Theme.Font.dataSmall)
    }
    private var open: some View { Button { perform(.open) } label: { Label("Open", systemImage: "play") }.buttonStyle(.borderedProminent).tint(Theme.Palette.ink.color) }
    private var copy: some View { Button { perform(.copy) } label: { Label("Copy", systemImage: "doc.on.doc") }.buttonStyle(.bordered) }
    private var share: some View { Button { perform(.share) } label: { Label("Share", systemImage: "square.and.arrow.up") }.buttonStyle(.bordered) }
    private var reveal: some View { Button { perform(.reveal) } label: { Label("Reveal", systemImage: "folder") }.buttonStyle(.bordered) }
    private func perform(_ action: StudioFileActions.Action) {
        guard presentation == nil else { return }
        Task { await fileActions.perform(action, url: url, claimClipboard: claimClipboard) }
    }
}
