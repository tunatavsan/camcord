import AppKit
import AVFoundation
import KeyboardShortcuts
import SwiftUI

/// Fast capture entry points and recording setup using the ordinary capture services.
struct CapturePanelView: View {
    @ObservedObject var model: RecordingStateModel
    let actions: PanelActions
    @State private var shortcuts: [CaptureKind: String] = [:]
    @State private var context: PanelPresentation
    /// One fixed dimension per state, so every row lands where it was designed to.
    static let panelWidth: CGFloat = 360
    static let panelHeight: CGFloat = 424
    static let activeHeight: CGFloat = 424
    static let finishingHeight: CGFloat = 220
    static let finishedHeight: CGFloat = 418
    static let recentThumbHeight: CGFloat = 66

    static func height(state: RecordingController.UIState, isFinishing: Bool, finished: Bool) -> CGFloat {
        if finished { return finishedHeight }
        if isFinishing { return finishingHeight }
        return state == .idle ? panelHeight : activeHeight
    }
    // Geometry used by the independent recording stage.
    static let contextColumnWidth: CGFloat = 248
    static let controlColumnWidth: CGFloat = 276
    static let cardWidth: CGFloat = 296
    static let panelSpring = Theme.Motion.panel

    init(model: RecordingStateModel, actions: PanelActions,
         library: LibraryStore? = nil, defaults: UserDefaults? = nil) {
        self.model = model
        self.actions = actions
        _context = State(initialValue: PanelPresentation(library: library, defaults: defaults))
    }

    private var canConfigure: Bool { model.state == .idle && !model.isStarting && !model.isArmed }
    private var currentHeight: CGFloat {
        Self.height(state: model.state, isFinishing: model.isFinishing, finished: model.finishedURL != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            PanelHeader(model: model)
            if let url = model.finishedURL {
                FinishedCard(url: url, reveal: actions.revealRecording, open: actions.openRecording,
                    renamed: { renamed in if model.finishedURL == url { model.finishedURL = renamed } },
                    dismiss: { model.finishedURL = nil })
            } else if model.isFinishing {
                FinishingCard().frame(maxHeight: .infinity)
            } else {
                PanelCaptureKeys(shortcuts: shortcuts, canCapture: canConfigure, perform: actions.perform)
                PanelRecordingModule(model: model, context: context, actions: actions, canConfigure: canConfigure)
                PanelRecentCaptures(items: context.recent, images: context.thumbnails,
                                    loading: context.library?.isLoading == true,
                                    issue: context.library?.loadingIssue, open: openCapture)
                    .padding(.top, Theme.Space.xs)
                Spacer(minLength: 0)
            }
            PanelFooter(actions: actions)
        }
        .padding(Theme.Space.l)
        .frame(width: Self.panelWidth, height: currentHeight, alignment: .top)
        .foregroundStyle(Theme.Palette.ink.color)
        .tint(Theme.Palette.ink.color)
        .modifier(PanelChrome())
        .onAppear(perform: panelAppeared)
        .onDisappear { context.synchronize(visible: false) }
        .onChange(of: model.isPanelVisible) { _, visible in
            context.synchronize(visible: visible, reloadSettings: visible)
        }
        .onChange(of: context.library?.items) { _, _ in context.synchronize(visible: model.isPanelVisible) }
        .onChange(of: model.panelOpenToken) { _, _ in
            model.finishedURL = nil
            reloadShortcuts()
            context.synchronize(visible: model.isPanelVisible, reloadSettings: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: RecordingSettings.didChangeNotification)) { _ in
            context.synchronize(visible: model.isPanelVisible, reloadSettings: true)
        }
    }

    private func panelAppeared() {
        reloadShortcuts()
        context.synchronize(visible: model.isPanelVisible, reloadSettings: true)
    }
    private func openCapture(_ item: CaptureItem) { Task { await context.open(item) } }
    private func reloadShortcuts() {
        shortcuts = Dictionary(uniqueKeysWithValues: CaptureKind.allCases.compactMap { kind in
            kind.shortcut.map { (kind, $0.description) }
        })
    }
}

private struct PanelHeader: View {
    @ObservedObject var model: RecordingStateModel
    var body: some View {
        HStack(spacing: Theme.Space.s) {
            CamcordBrandMark().frame(width: Theme.Menu.mark, height: Theme.Menu.mark)
            Text("Camcord").font(Theme.Font.bodyStrong)
            Spacer(minLength: 0)
            if model.state != .idle {
                Circle().fill(model.state == .paused ? Theme.Palette.ink3.color : Theme.Palette.record.color)
                    .frame(width: 6, height: 6).accessibilityHidden(true)
                Text(model.state == .paused ? "Paused" : "Recording")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.ink2.color)
                if let elapsed = model.elapsed {
                    Text(verbatim: elapsed).font(Theme.Font.dataStrong)
                        .accessibilityLabel(Text("Elapsed time"))
                }
            } else if model.isFinishing || model.isArmed {
                Text(model.isFinishing ? "Finalizing…" : "Ready to start")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.ink3.color)
            }
        }
        .frame(height: 26)
    }
}

private struct PanelCaptureKeys: View {
    let shortcuts: [CaptureKind: String]
    let canCapture: Bool
    let perform: (CaptureKind) -> Void
    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(CaptureKind.allCases) { kind in
                Button { perform(kind) } label: {
                    VStack(spacing: Theme.Space.s) {
                        Image(systemName: kind.symbol).font(Theme.Font.row)
                            .symbolRenderingMode(.monochrome).frame(height: 22)
                        Text(kind.shortTitle).font(Theme.Font.captionStrong).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity).frame(height: 66)
                }
                .buttonStyle(PanelHoverStyle(radius: Theme.Radius.thumb))
                .background(Theme.Palette.selection.color, in: .rect(cornerRadius: Theme.Radius.thumb))
                .accessibilityLabel(Text(kind.actionTitle))
                .help(Text(verbatim: help(kind)))
            }
        }
        .disabled(!canCapture)
    }
    private func help(_ kind: CaptureKind) -> String {
        guard canCapture else { return String(localized: "Finish or cancel the recording before capturing a screenshot") }
        let title = String(localized: kind.actionTitle)
        return shortcuts[kind].map { title + " · " + $0 } ?? title
    }
}

private struct PanelRecordingModule: View {
    @ObservedObject var model: RecordingStateModel
    let context: PanelPresentation
    let actions: PanelActions
    let canConfigure: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Menu {
                    ForEach(PanelRecordingSource.allCases) { source in
                        Button { context.selectSource(source, canConfigure: canConfigure) } label: {
                            Label(source.label, systemImage: source.symbol)
                        }
                    }
                } label: {
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: canConfigure ? context.recordingSource.symbol : model.isArmed ? "macwindow" : "record.circle")
                            .foregroundStyle(Theme.Palette.ink2.color)
                        Text(canConfigure ? context.recordingSource.label : "Source locked").font(Theme.Font.bodyStrong)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down").font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.ink3.color)
                    }
                    .padding(.horizontal, Theme.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading).frame(height: 36)
                    .background(Theme.Palette.hover.color, in: .capsule)
                    .contentShape(.capsule)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .disabled(!canConfigure)
                .help("Choose what the Record button captures")
                .accessibilityLabel("Recording source")
                .accessibilityValue(Text(canConfigure ? context.recordingSource.label : "Source locked"))
                PanelDeviceButton(title: "Camera", symbol: "video", enabled: context.settings?.camera.enabled == true,
                                  available: canConfigure && context.settings != nil,
                                  action: { context.toggleCamera(canConfigure: canConfigure) })
                PanelDeviceButton(title: "Microphone", symbol: "mic", enabled: context.settings?.microphone == true,
                                  available: canConfigure && context.settings != nil,
                                  action: { context.toggleMicrophone(canConfigure: canConfigure) })
            }
            PanelRecordingControls(model: model, context: context, actions: actions)
        }
        .padding(Theme.Space.s + Theme.Space.xs)
        .background(Theme.Palette.selection.color, in: .rect(cornerRadius: Theme.Radius.box))
    }
}

private struct PanelDeviceButton: View {
    let title: LocalizedStringKey
    let symbol: String
    let enabled: Bool
    let available: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: enabled ? symbol : symbol + ".slash")
                .font(Theme.Font.row).frame(width: 36, height: 36)
                .foregroundStyle(enabled ? Theme.Palette.ink.color : Theme.Palette.ink3.color)
                .background(enabled ? Theme.Palette.selectionStrong.color : Theme.Palette.hover.color, in: .circle)
        }
        .buttonStyle(.plain).disabled(!available)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(enabled ? "On" : "Off"))
        .accessibilityAddTraits(enabled ? .isSelected : [])
        .help(Text(available ? enabled ? "Disable for the next recording" : "Enable for the next recording" : "Finish or cancel recording to change this setting"))
    }
}

private struct PanelRecordingControls: View {
    @ObservedObject var model: RecordingStateModel
    let context: PanelPresentation
    let actions: PanelActions
    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if model.isArmed {
                Button("Cancel", action: actions.cancelArmed).keyboardShortcut(.cancelAction)
                    .buttonStyle(PanelSecondaryStyle())
                PanelPrimaryButton(title: "Start", symbol: "record.circle", action: actions.toggleRecording)
            } else if model.isStarting {
                ProgressView().controlSize(.small)
                Text("Preparing recording…").font(Theme.Font.body)
                Spacer(minLength: 0)
            } else if model.state != .idle {
                Button(action: actions.pauseResume) {
                    Label(model.state == .paused ? "Resume" : "Pause", systemImage: model.state == .paused ? "play.fill" : "pause")
                        .font(Theme.Font.bodyStrong).frame(maxWidth: .infinity)
                }.buttonStyle(PanelSecondaryStyle())
                PanelPrimaryButton(title: "Stop", symbol: "stop.fill", action: actions.toggleRecording)
            } else {
                PanelPrimaryButton(title: "Record", symbol: "record.circle",
                                   action: { context.startRecording(using: actions) })
                    .help(KeyboardShortcuts.getShortcut(for: .toggleRecording)?.description ?? String(localized: "Start recording"))
            }
        }.frame(height: 36)
    }
}

private struct PanelPrimaryButton: View {
    let title: LocalizedStringKey
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(Theme.Font.bodyStrong)
                .frame(maxWidth: .infinity).frame(height: 36)
        }
        .buttonStyle(PanelPrimaryStyle())
    }
}

private struct PanelRecentCaptures: View {
    let items: [CaptureItem]
    let images: [String: CGImage]
    let loading: Bool
    let issue: String?
    let open: (CaptureItem) -> Void
    /// Three fixed tiles side by side. Each shows the whole capture, scaled to fit, never
    /// cropped (owner, 2026-10-02), whatever its shape.
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Recent captures").font(Theme.Font.captionStrong).foregroundStyle(Theme.Palette.ink3.color)
            if items.isEmpty {
                Label(loading ? "Loading captures…" : issue == nil ? "No captures yet" : "Captures unavailable",
                      systemImage: loading ? "clock" : "photo")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.ink3.color)
                    .frame(maxWidth: .infinity, minHeight: CapturePanelView.recentThumbHeight)
                    .background(Theme.Palette.well.color, in: .rect(cornerRadius: Theme.Radius.thumb))
                    .help(Text(verbatim: issue ?? ""))
            } else {
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    ForEach(0..<3, id: \.self) { index in
                        if index < items.count {
                            tile(items[index])
                        } else {
                            Color.clear.frame(maxWidth: .infinity, minHeight: CapturePanelView.recentThumbHeight)
                        }
                    }
                }
            }
        }
    }

    private func tile(_ item: CaptureItem) -> some View {
        Button { open(item) } label: {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                ZStack {
                    Theme.Palette.well.color
                    if let image = images[item.id] {
                        Image(decorative: image, scale: 1).resizable().scaledToFit()
                            .clipShape(.rect(cornerRadius: Theme.Radius.badge))
                            .padding(Theme.Space.xs)
                    } else {
                        Image(systemName: item.kind == .recording ? "film" : "photo")
                            .foregroundStyle(Theme.Palette.ink3.color)
                    }
                }
                .frame(maxWidth: .infinity).frame(height: CapturePanelView.recentThumbHeight)
                .clipShape(.rect(cornerRadius: Theme.Radius.thumb))
                Text(verbatim: PanelRelativeDate.string(for: item.createdAt))
                    .font(Theme.Font.dataSmall).foregroundStyle(Theme.Palette.ink3.color)
                    .lineLimit(1).padding(.horizontal, Theme.Space.xs)
            }
            .padding(Theme.Space.xs / 2)
        }
        .buttonStyle(PanelHoverStyle(radius: Theme.Radius.thumb))
        .frame(maxWidth: .infinity)
        .onDrag { PanelCaptureDrag(item: item)?.provider() ?? NSItemProvider() }
        .help(Text(verbatim: item.title))
        .accessibilityLabel(Text(verbatim: item.title))
        .accessibilityHint(Text("Opens the capture; drag to use its file", comment: "Accessibility: recent capture tile"))
    }
}

/// Calendar-aware relative wording from the system locale, rather than elapsed duration.
enum PanelRelativeDate {
    static func string(for date: Date, relativeTo reference: Date = Date(), locale: Locale = .current) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: reference)
    }
}

private struct PanelFooter: View {
    let actions: PanelActions
    var body: some View {
        HStack {
            Button(action: actions.openMainWindow) {
                HStack(spacing: Theme.Space.m) { Text("Open Camcord"); Text(verbatim: "⌘0").font(Theme.Font.dataSmall).foregroundStyle(Theme.Palette.ink3.color) }
            }
                .keyboardShortcut("0", modifiers: .command)
                .buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
            Spacer()
            Menu {
                Button("Library", action: actions.openLibrary)
                Button("Edit", action: actions.openEditor)
                Button("Studio", action: actions.openStudio)
                Divider()
                Button("Quit Camcord", action: actions.quit).keyboardShortcut("q", modifiers: .command)
            } label: { Image(systemName: "ellipsis").frame(width: Theme.Menu.footerHeight, height: Theme.Menu.footerHeight) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).help("More destinations")
            Button(action: actions.openSettings) {
                Image(systemName: "gearshape")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.ink2.color)
                    .frame(width: Theme.Menu.footerHeight, height: Theme.Menu.footerHeight)
            }.buttonStyle(.plain).help("Settings").accessibilityLabel("Settings")
        }.font(Theme.Font.body).frame(height: Theme.Menu.footerHeight)
    }
}

private struct PanelHoverStyle: ButtonStyle {
    let radius: CGFloat
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(.rect(cornerRadius: radius))
            .background(configuration.isPressed ? Theme.Palette.pressed.color : hovered ? Theme.Palette.hover.color : .clear,
                        in: .rect(cornerRadius: radius))
            .onHover { hovered = $0 }
    }
}

private struct PanelPrimaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(Theme.Palette.onRecord.color)
            .background(configuration.isPressed ? Theme.Palette.recordHover.color : Theme.Palette.record.color,
                        in: .capsule)
            .contentShape(.capsule)
    }
}

private struct PanelSecondaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, Theme.Space.m).frame(height: 36)
            .background(configuration.isPressed ? Theme.Palette.pressed.color : Theme.Palette.hover.color,
                        in: .capsule)
            .contentShape(.capsule)
    }
}

private struct FinishingCard: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Finalizing recording…")
                .font(Theme.Font.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 12)
    }
}

/// The "recording done" card: an animated check, an inline RENAME field, file metadata
/// (size + duration + dimensions), and reveal/open actions. Stays until dismissed or the
/// panel is reopened — it deliberately does NOT snap back to the capture grid.
private struct FinishedCard: View {
    let reveal: (URL) -> Void
    let open: (URL) -> Void
    let renamed: (URL) -> Void
    let dismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var currentURL: URL
    @State private var name: String
    @State private var presentation: RecordingPresentation?
    @State private var renameMessage: String?
    @State private var isRenaming = false

    init(
        url: URL,
        reveal: @escaping (URL) -> Void,
        open: @escaping (URL) -> Void,
        renamed: @escaping (URL) -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.reveal = reveal
        self.open = open
        self.renamed = renamed
        self.dismiss = dismiss
        _currentURL = State(initialValue: url)
        _name = State(initialValue: url.deletingPathExtension().lastPathComponent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(Theme.Palette.ok.color.opacity(0.14)).frame(width: 28, height: 28)
                        .scaleEffect(appeared ? 1 : 0.5).opacity(appeared ? 1 : 0)
                    Image(systemName: "checkmark").font(Theme.Font.body).foregroundStyle(Theme.Palette.ok.color)
                        .scaleEffect(appeared ? 1 : 0.2).opacity(appeared ? 1 : 0)
                }
                Text("Recording ready").font(Theme.Font.body)
                Spacer()
                HoverScaleButton(action: dismiss) { hovering in
                    Image(systemName: "xmark")
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 28)
                        .background(Circle().fill(Color.primary.opacity(hovering ? 0.10 : 0.045)))
                }
                .disabled(isRenaming)
                .help("Close")
                .accessibilityLabel("Close")
            }

            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.well, style: .continuous)
                    .fill(Theme.Palette.hover.color)
                if let thumbnail = presentation?.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.well, style: .continuous))
                        .padding(4)
                } else if presentation == nil {
                    ProgressView().controlSize(.small).accessibilityLabel("Loading recording preview")
                } else {
                    Label("Preview unavailable", systemImage: "film")
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 64)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recording preview")
            .accessibilityValue(presentation?.thumbnail == nil ? "Unavailable" : "Ready")

            HStack(spacing: 4) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Font.body)
                    .disabled(isRenaming)
                    .onSubmit { Task { _ = await commitRename() } }
                Text("." + currentURL.pathExtension)
                    .font(Theme.Font.body).monospaced()
                    .foregroundStyle(.secondary)
                if isRenaming { ProgressView().controlSize(.mini) }
            }

            HStack(spacing: 12) {
                MetaLabel(symbol: "internaldrive", text: presentation?.size ?? "…")
                MetaLabel(symbol: "clock", text: presentation?.duration ?? "…")
                if let dims = presentation?.dimensions {
                    MetaLabel(symbol: "rectangle.ratio.16.to.9", text: dims)
                }
                Spacer()
            }
            .font(Theme.Font.body)
            .foregroundStyle(.secondary)

            if let renameMessage {
                Label(renameMessage, systemImage: "exclamationmark.circle.fill")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.record.color)
                    .lineLimit(1)
                    .accessibilityLabel(renameMessage)
            }

            Label {
                Text((currentURL.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "folder")
            }
            .font(Theme.Font.body)
            .foregroundStyle(.secondary)
            .help(currentURL.deletingLastPathComponent().path)
            .accessibilityLabel("Recording folder")
            .accessibilityValue(currentURL.deletingLastPathComponent().path)

            Spacer(minLength: 2)

            HStack(spacing: 8) {
                CardButton(title: "Show in Finder", symbol: "folder") {
                    Task { await performAfterRename(reveal) }
                }
                CardButton(title: "Open", symbol: "play.fill", prominent: true) {
                    Task { await performAfterRename(open) }
                }
            }
            .disabled(isRenaming)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(Theme.Space.s)
        .onAppear {
            if reduceMotion { appeared = true }
            else { withAnimation(CapturePanelView.panelSpring) { appeared = true } }
        }
        .task(id: currentURL) {
            let requestedURL = currentURL
            presentation = nil
            let loaded = await RecordingPresentation.load(requestedURL)
            guard !Task.isCancelled, currentURL == requestedURL else { return }
            presentation = loaded
        }
    }

    private func performAfterRename(_ action: @escaping (URL) -> Void) async {
        guard let url = await commitRename() else { return }
        action(url)
    }

    /// File-system validation and movement stay off the main actor. Actions wait for this
    /// result, and a collision/failure remains visible instead of silently reverting text.
    private func commitRename() async -> URL? {
        guard !isRenaming else { return nil }
        renameMessage = nil
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = currentURL.deletingPathExtension().lastPathComponent
        guard !cleaned.isEmpty else {
            renameMessage = String(localized: "The file name cannot be empty.")
            return nil
        }
        guard cleaned.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:").union(.controlCharacters)) == nil else {
            renameMessage = String(localized: "The file name cannot contain slashes, a colon or control characters.")
            return nil
        }
        if cleaned == original {
            name = cleaned
            return currentURL
        }
        let target = currentURL.deletingLastPathComponent()
            .appendingPathComponent(cleaned).appendingPathExtension(currentURL.pathExtension)
        isRenaming = true
        defer { isRenaming = false }
        switch await RecordingRename.move(from: currentURL, to: target) {
        case .success:
            currentURL = target
            name = cleaned
            renamed(target)
            return target
        case .collision:
            renameMessage = String(localized: "A recording with this name already exists.")
        case .failure:
            renameMessage = String(localized: "The file could not be renamed. Check folder permissions.")
        }
        return nil
    }
}

/// A small icon + value pair for the finished card's metadata row.
private struct MetaLabel: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(Theme.Font.body)
            Text(text).monospacedDigit()
        }
    }
}

/// Poster frame and metadata are loaded asynchronously from the actual completed file.
private struct RecordingPresentation: @unchecked Sendable {
    let thumbnail: NSImage?
    let size: String
    let duration: String
    let dimensions: String?

    static func load(_ url: URL) async -> RecordingPresentation {
        let asset = AVURLAsset(url: url)
        var durationText = "—"
        var previewTime = CMTime.zero
        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds >= 0 {
                durationText = timeString(seconds)
                previewTime = CMTime(seconds: min(max(seconds * 0.15, 0), 1), preferredTimescale: 600)
            }
        }
        var dims: String?
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
            let natural = try? await track.load(.naturalSize) {
            dims = "\(Int(abs(natural.width)))×\(Int(abs(natural.height)))"
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 592, height: 288)
        let thumbnail: NSImage?
        if let result = try? await generator.image(at: previewTime) {
            thumbnail = NSImage(cgImage: result.image, size: .zero)
        } else {
            thumbnail = nil
        }
        return RecordingPresentation(
            thumbnail: thumbnail,
            size: byteString(url),
            duration: durationText,
            dimensions: dims
        )
    }

    private static func byteString(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private static func timeString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

enum RecordingRename {
    enum Outcome: Sendable, Equatable { case success, collision, failure }

    static func move(from source: URL, to target: URL) async -> Outcome {
        await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: target.path) {
                // A case-insensitive volume reports a capitalization-only target as
                // existing even though it is the source itself. Prove both paths name
                // the same inode before asking the filesystem for an in-place rename;
                // every other existing target remains a collision.
                guard isSafeCaseOnlyRename(
                    from: source,
                    to: target,
                    fileManager: fileManager
                ) else { return .collision }
                do {
                    try fileManager.moveItem(at: source, to: target)
                    return .success
                } catch {
                    return .failure
                }
            }
            do {
                try fileManager.moveItem(at: source, to: target)
                return .success
            } catch {
                return fileManager.fileExists(atPath: target.path) ? .collision : .failure
            }
        }.value
    }

    private static func isSafeCaseOnlyRename(
        from source: URL,
        to target: URL,
        fileManager: FileManager
    ) -> Bool {
        let sourcePath = source.standardizedFileURL.path
        let targetPath = target.standardizedFileURL.path
        guard sourcePath != targetPath,
              sourcePath.caseInsensitiveCompare(targetPath) == .orderedSame,
              let supportsCaseSensitiveNames = try? source.deletingLastPathComponent()
                .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                .volumeSupportsCaseSensitiveNames,
              supportsCaseSensitiveNames == false,
              let sourceAttributes = try? fileManager.attributesOfItem(atPath: sourcePath),
              let targetAttributes = try? fileManager.attributesOfItem(atPath: targetPath),
              let sourceDevice = sourceAttributes[.systemNumber] as? NSNumber,
              let targetDevice = targetAttributes[.systemNumber] as? NSNumber,
              let sourceInode = sourceAttributes[.systemFileNumber] as? NSNumber,
              let targetInode = targetAttributes[.systemFileNumber] as? NSNumber
        else { return false }
        return sourceDevice == targetDevice && sourceInode == targetInode
    }
}

/// A pill button used in the finished card. `prominent` gives it a filled accent look.
private struct CardButton: View {
    let title: String
    let symbol: String
    var prominent: Bool = false
    let action: () -> Void

    var body: some View {
        HoverScaleButton(action: action) { hovering in
            HStack(spacing: 5) {
                Image(systemName: symbol).font(Theme.Font.body)
                Text(title).font(Theme.Font.body)
            }
            .foregroundStyle(prominent ? AnyShapeStyle(Theme.Palette.onInk.color) : AnyShapeStyle(Theme.Palette.ink.color))
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.well, style: .continuous)
                    .fill(prominent
                        ? AnyShapeStyle(Theme.Palette.ink.color.opacity(hovering ? 1 : 0.92))
                        : AnyShapeStyle(hovering ? Theme.Palette.pressed.color : Theme.Palette.hover.color))
            )
        }
        .help(title)
        .accessibilityLabel(title)
    }
}

// MARK: - Components

/// One capture action: icon over a tiny label, generous hit target, soft hover fill,
/// gentle press scale.
private struct HoverScaleButton<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: (Bool) -> Content

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            content(hovering)
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.well))
        }
        .buttonStyle(PressScaleStyle(reduceMotion: reduceMotion))
        .onHover { isHovering in
            if reduceMotion {
                hovering = isHovering
            } else {
                withAnimation(.easeOut(duration: 0.14)) {
                    hovering = isHovering
                }
            }
        }
    }
}

private struct PressScaleStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.965 : 1)
            .animation(
                reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.84),
                value: configuration.isPressed
            )
    }
}

private struct PanelChrome: ViewModifier {
    @Environment(\.camcordOpaqueMaterialPreview) private var opaquePreview
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.background {
            if opaquePreview || reduceTransparency {
                RoundedRectangle(cornerRadius: Theme.Radius.floating)
                    .fill(Theme.Palette.glassSolidChrome.color)
            } else {
                // The left sidebar's own recipe: one untinted native glass region, nothing
                // behind it. SwiftUI controls remain above it, so their fills are not glass content.
                PanelGlassBackground(appearance: colorScheme == .dark ? .darkAqua : .aqua)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

}

/// One untinted system glass region, with stable explicit light/dark appearance.
private struct PanelGlassBackground: NSViewRepresentable {
    let appearance: NSAppearance.Name

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.contentView = NSView()
        view.setAccessibilityHidden(true)
        view.adoptSidebarGlass()
        configure(view)
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        configure(view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSGlassEffectView,
                     context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    private func configure(_ view: NSGlassEffectView) {
        if view.style != .regular { view.style = .regular }
        if view.cornerRadius != Theme.Radius.floating { view.cornerRadius = Theme.Radius.floating }
        if view.tintColor != nil { view.tintColor = nil }
        if view.appearance?.name != appearance { view.appearance = NSAppearance(named: appearance) }
    }
}
