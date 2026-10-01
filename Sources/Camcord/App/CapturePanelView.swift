import AppKit
import AVFoundation
import KeyboardShortcuts
import SwiftUI

/// Fast capture entry points. Recording setup and source previews belong to Studio.
struct CapturePanelView: View {
    @ObservedObject var model: RecordingStateModel
    let actions: PanelActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shortcuts: [CaptureKind: String] = [:]
    @State private var context: PanelPresentation
    static let panelWidth: CGFloat = 320
    static let panelHeight: CGFloat = 370
    static let activeHeight: CGFloat = 370
    static let finishingHeight: CGFloat = 220
    static let finishedHeight: CGFloat = 418
    // Preserved for independent StageView geometry clients; the palette has no stage.
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

    private var currentHeight: CGFloat {
        if model.finishedURL != nil { return Self.finishedHeight }
        if model.isFinishing { return Self.finishingHeight }
        return model.state == .idle ? Self.panelHeight : Self.activeHeight
    }

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            PanelHeader(state: model.state, elapsed: model.elapsed)
            if let url = model.finishedURL {
                FinishedCard(url: url, reveal: actions.revealRecording, open: actions.openRecording,
                    renamed: { renamed in if model.finishedURL == url { model.finishedURL = renamed } },
                    dismiss: { model.finishedURL = nil })
            } else if model.isFinishing {
                FinishingCard().frame(maxHeight: .infinity)
            } else {
                PanelSectionLabel(title: "Screenshot")
                PanelCaptureKeys(shortcuts: shortcuts,
                                 disabledReason: model.isStarting || model.isArmed || model.state != .idle
                                    ? String(localized: "Finish or cancel the recording before capturing a screenshot") : nil,
                                 perform: actions.perform)
                    .disabled(model.isStarting || model.isArmed || model.state != .idle)
                PanelSectionLabel(title: "Record")
                PanelContextChips(settings: context.settings, health: model.health,
                                  state: model.state, actions: actions,
                                  canChooseSource: model.state == .idle && !model.isStarting && !model.isArmed)
                PanelRecordingControls(model: model, actions: actions)
                if let library = context.library {
                    PanelLastCapture(item: context.latest, image: context.thumbnail,
                                     loading: library.isLoading, issue: library.loadingIssue,
                                     open: openCapture)
                }
            }
            PanelFooter(actions: actions)
        }
        .padding(Theme.Space.m)
        .frame(width: Self.panelWidth, height: currentHeight, alignment: .top)
        .foregroundStyle(Theme.Palette.ink.color)
        .tint(Theme.Palette.ink.color)
        .modifier(PanelChrome())
        .animation(Theme.Motion.resolve(Self.panelSpring, reduceMotion: reduceMotion), value: currentHeight)
        .onAppear(perform: panelAppeared)
        .onDisappear { context.synchronize(visible: false) }
        .onChange(of: model.isPanelVisible) { _, visible in
            context.synchronize(visible: visible, reloadSettings: visible)
        }
        .onChange(of: context.library?.items) { _, _ in
            context.synchronize(visible: model.isPanelVisible)
        }
        .onChange(of: model.panelOpenToken) { _, _ in
            model.finishedURL = nil
            reloadShortcuts()
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
    let state: RecordingController.UIState
    let elapsed: String?
    var body: some View {
        HStack(spacing: Theme.Space.s) {
            ViewfinderMarkView().frame(width: Theme.Menu.mark, height: Theme.Menu.mark)
            Text("Camcord").font(Theme.Font.bodyStrong)
            Spacer()
            if state != .idle {
                Group {
                    if state == .paused { Circle().strokeBorder(Theme.Palette.ink.color, lineWidth: 1.5) }
                    else { Circle().fill(Theme.Palette.record.color) }
                }.frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                if let elapsed {
                    Text(verbatim: elapsed).font(Theme.Font.dataStrong)
                        .foregroundStyle(state == .paused ? Theme.Palette.ink.color : Theme.Palette.record.color)
                        .accessibilityLabel(Text(state == .paused ? "Paused" : "Recording"))
                        .accessibilityValue(Text(verbatim: elapsed))
                }
            }
        }
        .padding(.horizontal, Theme.Space.xs)
        .frame(height: Theme.Menu.headerHeight)
    }
}

private struct PanelSectionLabel: View {
    let title: LocalizedStringKey
    var body: some View {
        Text(title).font(Theme.Font.captionStrong).tracking(0.22)
            .foregroundStyle(Theme.Palette.ink3.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.xs)
            .frame(height: Theme.Menu.sectionHeight)
    }
}

private struct PanelCaptureKeys: View {
    let shortcuts: [CaptureKind: String]
    let disabledReason: String?
    let perform: (CaptureKind) -> Void
    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(CaptureKind.allCases) { kind in
                PanelCaptureKey(kind: kind, shortcut: shortcuts[kind], disabledReason: disabledReason, action: { perform(kind) })
            }
        }
        .padding(Theme.Space.xs)
        .background(Theme.Menu.inset.color, in: .rect(cornerRadius: Theme.Radius.well))
        .overlay { RoundedRectangle(cornerRadius: Theme.Radius.well).strokeBorder(Theme.Menu.line.color, lineWidth: 0.5) }
    }
}

private struct PanelCaptureKey: View {
    let kind: CaptureKind
    let shortcut: String?
    let disabledReason: String?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: Theme.Menu.keySymbolFont, weight: .regular))
                    .symbolRenderingMode(.monochrome)
                    .frame(width: Theme.Menu.keySymbol, height: Theme.Menu.keySymbol)
                Text(kind.shortTitle).font(Theme.Font.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity).frame(height: Theme.Menu.keyHeight)
        }
        .buttonStyle(PanelHoverStyle(radius: Theme.Radius.key))
        .accessibilityLabel(Text(kind.actionTitle))
        .help(Text(verbatim: help))
    }
    private var symbol: String {
        kind == .scroll ? "arrow.up.and.down.text.horizontal" : kind.symbol
    }
    private var help: String {
        if let disabledReason { return disabledReason }
        let title = String(localized: kind.actionTitle)
        return shortcut.map { title + " · " + $0 } ?? title
    }
}

private struct PanelContextChips: View {
    let settings: RecordingSettings?
    let health: RecordingHealth?
    let state: RecordingController.UIState
    let actions: PanelActions
    let canChooseSource: Bool
    private var cameraEnabled: Bool { settings?.camera.enabled == true }
    private var micEnabled: Bool { settings?.microphone == true }
    private var levels: AudioLevels? {
        guard state == .recording, health?.microphone.enabled == true,
              health?.microphone.isReceiving(at: ProcessInfo.processInfo.systemUptime) == true else { return nil }
        return health?.microphone.levels
    }
    var body: some View {
        HStack(spacing: Theme.Space.xs + 2) {
            Menu {
                Button("Record a region", action: actions.toggleRecording)
                Button("Record a window", action: actions.recordWindow)
                Button("Record the screen", action: actions.recordFullScreen)
            } label: {
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: "rectangle.dashed")
                    Text("Source").lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
                .frame(maxWidth: .infinity).frame(height: Theme.Menu.chipHeight)
                .contentShape(.capsule)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .frame(maxWidth: .infinity).frame(height: Theme.Menu.chipHeight)
            .disabled(!canChooseSource)
            .modifier(PanelChipSurface())
            .help(Text(canChooseSource ? "Choose a source for a fast recording" : "Finish or cancel the recording before choosing another source"))
            Button(action: actions.openStudio) {
                Label("Camera", systemImage: cameraEnabled || settings == nil ? "video" : "video.slash")
                    .frame(maxWidth: .infinity).frame(height: Theme.Menu.chipHeight)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity).frame(height: Theme.Menu.chipHeight)
            .modifier(PanelChipSurface())
            .help(Text(verbatim: cameraHelp))
            .accessibilityValue(Text(settings == nil ? "Setup in Studio" : cameraEnabled ? "Enabled for recording" : "Off"))
            Button(action: actions.openStudio) {
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: micEnabled || settings == nil ? "mic" : "mic.slash")
                    if let levels { AudioLevelMeter(levels: levels, active: true, height: 12).frame(width: 15, height: 12).accessibilityHidden(true) }
                    Text("Mic")
                }
                .frame(maxWidth: .infinity).frame(height: Theme.Menu.chipHeight)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity).frame(height: Theme.Menu.chipHeight)
            .modifier(PanelChipSurface())
            .help(Text(verbatim: microphoneHelp))
            .accessibilityValue(Text(settings == nil ? "Setup in Studio" : micEnabled ? "Enabled for recording" : "Off"))
        }
        .font(Theme.Font.caption)
    }
    private var cameraHelp: String {
        guard settings != nil else { return String(localized: "Camera setup is available in Studio") }
        if cameraEnabled && AVCaptureDevice.authorizationStatus(for: .video) == .denied {
            return String(localized: "Camera access is denied. Configure access in Studio.")
        }
        return cameraEnabled ? String(localized: "Camera enabled for future recordings. Configure in Studio.")
            : String(localized: "Camera is off. Configure in Studio.")
    }
    private var microphoneHelp: String {
        guard settings != nil else { return String(localized: "Microphone setup is available in Studio") }
        if micEnabled && AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
            return String(localized: "Microphone access is denied. Configure access in Studio.")
        }
        return micEnabled ? String(localized: "Microphone enabled for future recordings. Configure in Studio.")
            : String(localized: "Microphone is off. Configure in Studio.")
    }
}

private struct PanelRecordingControls: View {
    @ObservedObject var model: RecordingStateModel
    let actions: PanelActions
    var body: some View {
        HStack(spacing: Theme.Space.xs + 2) {
            if model.isArmed {
                PanelPrimaryButton(title: "Start", symbol: "record.circle", action: actions.toggleRecording)
                Button("Cancel", action: actions.cancelArmed).keyboardShortcut(.cancelAction)
                    .buttonStyle(PanelSecondaryStyle())
            } else if model.isStarting {
                HStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Preparing recording…").font(Theme.Font.body)
                }.frame(maxWidth: .infinity)
            } else if model.state != .idle {
                Button(action: actions.pauseResume) {
                    Label(model.state == .paused ? "Resume" : "Pause", systemImage: model.state == .paused ? "play.fill" : "pause")
                }.buttonStyle(PanelSecondaryStyle())
                PanelPrimaryButton(title: "Stop", symbol: "stop.fill", action: actions.toggleRecording)
            } else {
                PanelPrimaryButton(title: "Record", symbol: "circle.fill", action: actions.toggleRecording)
                    .help(KeyboardShortcuts.getShortcut(for: .toggleRecording)?.description ?? String(localized: "Start recording"))
            }
        }.frame(height: Theme.Menu.actionHeight)
    }
}

private struct PanelPrimaryButton: View {
    let title: LocalizedStringKey
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(title).font(Theme.Font.rowStrong)
            }
            .frame(maxWidth: .infinity).frame(height: Theme.Menu.actionHeight)
        }
        .buttonStyle(PanelPrimaryStyle())
    }
}

private struct PanelLastCapture: View {
    let item: CaptureItem?
    let image: CGImage?
    let loading: Bool
    let issue: String?
    let open: (CaptureItem) -> Void
    var body: some View {
        Group {
            if let item {
                Button { open(item) } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: Theme.Radius.key).fill(Theme.Menu.inset.color)
                            if let image {
                                Image(decorative: image, scale: 1).resizable().scaledToFill()
                            } else {
                                Image(systemName: item.kind == .recording ? "video" : "photo")
                                    .foregroundStyle(Theme.Palette.ink3.color)
                            }
                        }
                        .frame(width: Theme.Menu.thumbnail.width, height: Theme.Menu.thumbnail.height)
                        .clipShape(.rect(cornerRadius: Theme.Radius.key))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: item.title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                            HStack(spacing: Theme.Space.xs) {
                                Text(kindLabel(item.kind))
                                Text(verbatim: "·")
                                Text(verbatim: PanelRelativeDate.string(for: item.createdAt))
                            }.font(Theme.Font.dataSmall).foregroundStyle(Theme.Palette.ink3.color).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right").font(.system(size: 10))
                            .foregroundStyle(Theme.Palette.ink3.color).accessibilityHidden(true)
                    }
                    .padding(6)
                }
                .buttonStyle(PanelHoverStyle(radius: Theme.Radius.well + 2))
                .onDrag { PanelCaptureDrag(item: item)?.provider() ?? NSItemProvider() }
                .help("Open this capture or drag its file")
            } else {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: loading ? "clock" : "photo")
                    Text(loading ? "Loading captures…" : issue == nil ? "No captures yet" : "Captures unavailable")
                        .font(Theme.Font.caption)
                }.foregroundStyle(Theme.Palette.ink3.color).frame(maxWidth: .infinity)
                    .help(Text(verbatim: issue ?? ""))
            }
        }
        .frame(height: Theme.Menu.lastHeight)
        .overlay { RoundedRectangle(cornerRadius: Theme.Radius.well + 2).strokeBorder(Theme.Menu.line.color, lineWidth: 0.5) }
    }
    private func kindLabel(_ kind: CaptureItem.Kind) -> LocalizedStringKey {
        switch kind { case .screenshot: "Screenshot"; case .scrollCapture: "Scroll capture"; case .recording: "Recording" }
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
                .buttonStyle(PanelSecondaryStyle()).fixedSize(horizontal: true, vertical: false)
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
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Theme.Palette.ink2.color)
                    .frame(width: Theme.Menu.footerHeight, height: Theme.Menu.footerHeight)
            }.buttonStyle(.plain).help("Settings").accessibilityLabel("Settings")
        }.font(Theme.Font.body).frame(height: Theme.Menu.footerHeight)
    }
}

private struct PanelChipSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.background(Theme.Menu.inset.color, in: .capsule)
            .overlay { Capsule().strokeBorder(Theme.Menu.line.color, lineWidth: 0.5) }
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
                        in: .rect(cornerRadius: Theme.Radius.well))
            .contentShape(.rect(cornerRadius: Theme.Radius.well))
    }
}

private struct PanelSecondaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, Theme.Space.m)
            .background(configuration.isPressed ? Theme.Palette.pressed.color : .clear,
                        in: .rect(cornerRadius: Theme.Radius.well))
            .overlay { RoundedRectangle(cornerRadius: Theme.Radius.well).strokeBorder(Theme.Menu.line.color, lineWidth: 0.5) }
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
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.background {
            if opaquePreview || reduceTransparency {
                RoundedRectangle(cornerRadius: Theme.Radius.floating)
                    .fill(Theme.Palette.glassSolidChrome.color)
            } else {
                // A single native glass region owns the backdrop. SwiftUI controls
                // remain above it, so their opaque fills are not glass content.
                PanelGlassBackground(tint: resolvedTint,
                                     appearance: colorScheme == .dark ? .darkAqua : .aqua)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private var resolvedTint: NSColor {
        let variant: ThemeColor.Variant
        if contrast == .increased {
            variant = colorScheme == .dark ? .highContrastDark : .highContrastLight
        } else {
            variant = colorScheme == .dark ? .dark : .light
        }
        let value = Theme.Menu.glassTint.value(variant)
        return NSColor(srgbRed: CGFloat(value.red), green: CGFloat(value.green),
                       blue: CGFloat(value.blue), alpha: CGFloat(value.alpha))
    }
}

/// Menu-local Liquid Glass bridge, with explicit appearance and tint updates.
private struct PanelGlassBackground: NSViewRepresentable {
    let tint: NSColor
    let appearance: NSAppearance.Name

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.contentView = NSView()
        view.setAccessibilityHidden(true)
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
        view.style = .regular
        view.cornerRadius = Theme.Radius.floating
        view.tintColor = tint
        view.appearance = NSAppearance(named: appearance)
    }
}
