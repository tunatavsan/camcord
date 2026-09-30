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
    static let panelWidth: CGFloat = 320
    static let panelHeight: CGFloat = 428
    static let activeHeight: CGFloat = 428
    static let finishingHeight: CGFloat = 220
    static let finishedHeight: CGFloat = 418
    // Preserved for independent StageView geometry clients; the palette has no stage.
    static let contextColumnWidth: CGFloat = 248
    static let controlColumnWidth: CGFloat = 276
    static let cardWidth: CGFloat = 296
    static let panelSpring = Theme.Motion.panel

    private var currentHeight: CGFloat {
        if model.finishedURL != nil { return Self.finishedHeight }
        if model.isFinishing { return Self.finishingHeight }
        return model.state == .idle ? Self.panelHeight : Self.activeHeight
    }
    var body: some View {
        VStack(spacing: Theme.Space.m) {
            header
            if let url = model.finishedURL {
                FinishedCard(url: url, reveal: actions.revealRecording, open: actions.openRecording,
                    renamed: { renamed in if model.finishedURL == url { model.finishedURL = renamed } },
                    dismiss: { model.finishedURL = nil })
            } else if model.isFinishing {
                FinishingCard().frame(maxHeight: .infinity)
            } else {
                SectionHeader(title: "Screenshot")
                captureKeys
                SectionHeader(title: "Record")
                recordingControls
                Spacer(minLength: 0)
                destinations
            }
            HStack {
                Text("Camcord").font(Theme.Font.caption).foregroundStyle(Theme.Palette.ink3.color)
                Spacer()
                Button("Quit Camcord", action: actions.quit)
                    .buttonStyle(.plain).font(Theme.Font.caption)
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(Theme.Space.m)
        .frame(width: Self.panelWidth, height: currentHeight)
        .foregroundStyle(Theme.Palette.ink.color)
        .tint(Theme.Palette.ink.color)
        .modifier(PanelChrome())
        .animation(Theme.Motion.resolve(Self.panelSpring, reduceMotion: reduceMotion), value: currentHeight)
        .onAppear(perform: reloadShortcuts)
        .onChange(of: model.panelOpenToken) { _, _ in
            model.finishedURL = nil
            reloadShortcuts()
        }
    }
    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "camera.viewfinder").font(Theme.Font.row)
            Text("Camcord").font(Theme.Font.rowStrong)
            Spacer()
            if model.state != .idle {
                Image(systemName: model.state == .paused ? "pause.circle" : "record.circle.fill")
                    .foregroundStyle(model.state == .paused ? Theme.Palette.warn.color : Theme.Palette.record.color)
                Text(verbatim: model.elapsed ?? "0:00").font(Theme.Font.dataStrong)
                    .accessibilityLabel(Text(model.state == .paused ? "Paused" : "Recording"))
                    .accessibilityValue(model.elapsed ?? "0:00")
            }
        }
    }
    private var captureKeys: some View {
        InsetWell {
            VStack(spacing: Theme.Space.xs) {
                captureButton(.region, prominent: true)
                HStack(spacing: Theme.Space.xs) {
                    ForEach([CaptureKind.window, .screen, .scroll, .text]) { captureButton($0) }
                }
            }
        }
        .disabled(model.isStarting || model.isArmed || model.state != .idle)
    }
    private func captureButton(_ kind: CaptureKind, prominent: Bool = false) -> some View {
        Button { actions.perform(kind) } label: {
            VStack(spacing: Theme.Space.xs) {
                Label(kind.shortTitle, systemImage: kind.symbol)
                    .labelStyle(prominent ? AnyPanelLabelStyle.horizontal : AnyPanelLabelStyle.vertical)
                if let shortcut = shortcuts[kind] {
                    Text(verbatim: shortcut).font(Theme.Font.dataSmall).foregroundStyle(Theme.Palette.ink2.color)
                }
            }
            .font(prominent ? Theme.Font.bodyStrong : Theme.Font.caption)
            .frame(maxWidth: .infinity, minHeight: prominent ? 42 : 58)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.key))
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.key).fill(prominent ? Theme.Palette.selection.color : Theme.Palette.hover.color))
        .accessibilityLabel(Text(kind.actionTitle))
        .help(Text(kind.actionTitle))
    }
    @ViewBuilder private var recordingControls: some View {
        if model.isArmed {
            HStack {
                Button("Start", action: actions.toggleRecording).buttonStyle(.borderedProminent).tint(Theme.Palette.record.color)
                Button("Cancel", action: actions.cancelArmed).keyboardShortcut(.cancelAction)
            }
        } else if model.isStarting {
            HStack { ProgressView().controlSize(.small); Text("Preparing recording…").font(Theme.Font.body) }
                .frame(maxWidth: .infinity, minHeight: 42)
        } else if model.state != .idle {
            HStack {
                Button(model.state == .paused ? "Resume" : "Pause", action: actions.pauseResume)
                    .buttonStyle(.bordered).frame(maxWidth: .infinity)
                RecordButton(size: .bar, isRecording: true, action: actions.toggleRecording)
            }
        } else {
            HStack {
                RecordButton(size: .bar, action: actions.toggleRecording)
                Menu {
                    Button("Record a window", action: actions.recordWindow)
                    Button("Record the screen", action: actions.recordFullScreen)
                    Divider()
                    Button("Open Studio", action: actions.openStudio)
                } label: { Image(systemName: "chevron.down").accessibilityLabel("Recording target") }
                .menuStyle(.borderlessButton).frame(width: 24)
            }
            .help(KeyboardShortcuts.getShortcut(for: .toggleRecording)?.description ?? String(localized: "Start recording"))
        }
    }
    private var destinations: some View {
        VStack(spacing: Theme.Space.s) {
            Divider()
            HStack {
                destination("Library", symbol: "square.grid.2x2", action: actions.openLibrary)
                destination("Edit", symbol: "pencil.tip.crop.circle", action: actions.openEditor)
                destination("Studio", symbol: "video", action: actions.openStudio)
                destination("Settings", symbol: "gearshape", action: actions.openSettings)
            }
        }
    }
    private func destination(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).labelStyle(StackedLabelStyle()).frame(maxWidth: .infinity) }
            .buttonStyle(.plain).font(Theme.Font.caption)
    }
    private func reloadShortcuts() {
        shortcuts = Dictionary(uniqueKeysWithValues: CaptureKind.allCases.compactMap { kind in kind.shortcut.map { (kind, $0.description) } })
    }
}

/// One label style avoids type erasure in the capture button's conditional layout.
private enum AnyPanelLabelStyle: LabelStyle {
    case horizontal, vertical
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        switch self {
        case .horizontal: HStack { configuration.icon; configuration.title }
        case .vertical: VStack(spacing: Theme.Space.xs) { configuration.icon; configuration.title }
        }
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
    @ViewBuilder func body(content: Content) -> some View {
        if opaquePreview {
            content.background(RoundedRectangle(cornerRadius: Theme.Radius.floating).fill(Theme.Palette.glassSolidChrome.color))
        } else {
            content.camcordGlass(.chrome, in: RoundedRectangle(cornerRadius: Theme.Radius.floating))
        }
    }
}
