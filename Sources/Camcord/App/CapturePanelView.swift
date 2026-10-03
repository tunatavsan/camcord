import AppKit
import AVFoundation
import KeyboardShortcuts
import SwiftUI

/// The menu-bar panel: the window tray with four glass cells floating on it (capture, record,
/// recent captures, destinations). Nothing is written on the tray itself.
struct CapturePanelView: View {
    @ObservedObject var model: RecordingStateModel
    let actions: PanelActions
    @State private var shortcuts: [CaptureKind: String] = [:]
    @State private var context: PanelPresentation
    /// One fixed dimension per state, so every row lands where it was designed to.
    static let panelWidth: CGFloat = 360
    static let panelHeight: CGFloat = Layout.ring * 2 + Layout.captureCell + Layout.recordCell + Layout.recentCell
        + Layout.destinationsCell + Layout.gap * 3
    static let activeHeight: CGFloat = panelHeight
    static let finishingHeight: CGFloat = 220
    static let finishedHeight: CGFloat = 418
    static let recentThumbHeight: CGFloat = 64
    /// Concentric with the cells: their radius plus the tray's ring.
    static let cornerRadius: CGFloat = Theme.Radius.floating + Layout.ring

    enum Layout {
        static let ring: CGFloat = 8
        static let gap: CGFloat = 8
        static let padding: CGFloat = 12
        static let captureCell: CGFloat = 80
        static let recordCell: CGFloat = 112
        static let recentCell: CGFloat = 134
        static let destinationsCell: CGFloat = 44
    }

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
        VStack(spacing: Layout.gap) {
            if let url = model.finishedURL {
                PanelFinishedCell(url: url, reveal: actions.revealRecording, open: actions.openRecording,
                    renamed: { renamed in if model.finishedURL == url { model.finishedURL = renamed } },
                    dismiss: { model.finishedURL = nil })
            } else if model.isFinishing {
                PanelFinishingCell()
            } else {
                // Screenshots stay available while recording; only arming and startup pause them.
                PanelCaptureCell(shortcuts: shortcuts, canCapture: !model.isStarting && !model.isArmed, perform: actions.perform)
                    .frame(height: Layout.captureCell)
                PanelRecordCell(model: model, context: context, actions: actions, canConfigure: canConfigure)
                    .frame(height: Layout.recordCell)
                PanelRecentCell(items: context.recent, images: context.thumbnails,
                                loading: context.library?.isLoading == true,
                                issue: context.library?.loadingIssue, open: openCapture, showAll: actions.openLibrary)
                    .frame(height: Layout.recentCell)
            }
            PanelDestinationsCell(actions: actions).frame(height: Layout.destinationsCell)
        }
        .padding(Layout.ring)
        .frame(width: Self.panelWidth, height: currentHeight, alignment: .top)
        .foregroundStyle(Theme.Palette.ink.color)
        .tint(Theme.Palette.ink.color)
        .modifier(PanelTray())
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
    private func openCapture(_ item: CaptureItem) {
        if item.kind != .recording, let preview = actions.previewCapture { preview(item); return }
        Task { await context.open(item) }
    }
    private func reloadShortcuts() {
        shortcuts = Dictionary(uniqueKeysWithValues: CaptureKind.allCases.compactMap { kind in
            kind.shortcut.map { (kind, $0.description) }
        })
    }
}

// MARK: - Cells

extension View {
    /// One floating cell: the main window's pane glass, its radius and its inset.
    func panelCell() -> some View { modifier(PanelCell()) }
}

private struct PanelCell: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.camcordOpaqueMaterialPreview) private var opaquePreview
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                if reduceTransparency || opaquePreview {
                    RoundedRectangle(cornerRadius: Theme.Radius.floating, style: .continuous)
                        .fill(Theme.Palette.glassSolidSidebar.color)
                } else {
                    PaneGlass(cornerRadius: Theme.Radius.floating).allowsHitTesting(false)
                }
            }
            .clipShape(.rect(cornerRadius: Theme.Radius.floating, style: .continuous))
    }
}

/// The five captures, evenly spaced and centred on their ink. Hovering one raises and lights
/// its symbol, shows its shortcut in place of its name, and the others step back.
private struct PanelCaptureCell: View {
    let shortcuts: [CaptureKind: String]
    let canCapture: Bool
    let perform: (CaptureKind) -> Void
    @State private var focus: CaptureKind?
    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            ForEach(CaptureKind.allCases) { kind in
                PanelToolButton(symbol: kind.symbol, title: Text(kind.shortTitle), detail: shortcuts[kind],
                                focus: focus.map { $0 == kind }) {
                    perform(kind)
                } hover: { inside in
                    if inside { focus = kind } else if focus == kind { focus = nil }
                }
                .accessibilityLabel(Text(kind.actionTitle))
                .accessibilityHint(Text(verbatim: shortcuts[kind] ?? ""))
                Spacer(minLength: 0)
            }
        }
        .frame(maxHeight: .infinity)
        .disabled(!canCapture)
        .help(canCapture ? Text(verbatim: "") : Text("Finish or cancel the recording before capturing a screenshot"))
        .panelCell()
    }
}

/// A symbol over its name. Hovered it rises, grows and glows and its detail (a shortcut)
/// takes the name's place; when a sibling is hovered it steps back; pressed it gives.
private struct PanelToolButton: View {
    let symbol: String
    let title: Text
    let detail: String?
    /// nil: nothing in the row is hovered; true: this one; false: a sibling.
    let focus: Bool?
    let action: () -> Void
    let hover: (Bool) -> Void
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let lifted = focus == true && enabled
        Button(action: action) {
            VStack(spacing: 5) {
                InkSymbol(name: symbol, pointSize: 18, canvas: 26)
                    .scaleEffect(lifted && !reduceMotion ? 1.16 : 1)
                    .offset(y: lifted && !reduceMotion ? -2 : 0)
                    .shadow(color: Theme.Palette.ink.color.opacity(lifted ? 0.45 : 0), radius: 7)
                ZStack {
                    title.font(Theme.Font.captionStrong).lineLimit(1).fixedSize()
                        .opacity(lifted && detail != nil ? 0 : 1)
                    if let detail {
                        Text(verbatim: detail).font(Theme.Font.dataSmall).lineLimit(1).fixedSize()
                            .foregroundStyle(Theme.Palette.ink2.color)
                            .opacity(lifted ? 1 : 0)
                            .offset(y: lifted || reduceMotion ? 0 : 3)
                    }
                }
                .frame(height: 15)
            }
            .padding(.horizontal, 4)
            .frame(height: 56)
            .opacity(enabled ? (focus == false ? 0.5 : 1) : 0.35)
            .contentShape(.rect)
        }
        .buttonStyle(PanelPressStyle())
        .onHover(perform: hover)
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.62), value: focus)
    }
}

/// What the Record button records and with which devices, then the button itself; while
/// recording, the time and the controls.
private struct PanelRecordCell: View {
    @ObservedObject var model: RecordingStateModel
    let context: PanelPresentation
    let actions: PanelActions
    let canConfigure: Bool
    /// One control in focus at a time across the row, like the capture tools.
    @State private var focus: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.state == .idle && !model.isArmed && !model.isStarting {
                HStack(spacing: 4) {
                    ForEach(PanelRecordingSource.allCases) { source in
                        PanelChip(symbol: source.symbol, title: Text(source.label), selected: context.recordingSource == source,
                                  focus: focusState(source.rawValue), action: {
                            context.selectSource(source, canConfigure: canConfigure)
                        }, hover: hover(source.rawValue))
                    }
                    Spacer(minLength: 4)
                    PanelDeviceToggle(title: "Camera", symbol: "video", on: context.settings?.camera.enabled == true,
                                      available: canConfigure && context.settings != nil, focus: focusState("camera"),
                                      action: { context.toggleCamera(canConfigure: canConfigure) }, hover: hover("camera"))
                    PanelDeviceToggle(title: "Microphone", symbol: "mic", on: context.settings?.microphone == true,
                                      available: canConfigure && context.settings != nil, focus: focusState("mic"),
                                      action: { context.toggleMicrophone(canConfigure: canConfigure) }, hover: hover("mic"))
                }
                .frame(height: 32)
            } else {
                PanelRecordingStatus(model: model).frame(height: 32)
            }
            PanelRecordingControls(model: model, context: context, actions: actions)
        }
        .padding(CapturePanelView.Layout.padding)
        .panelCell()
    }
    private func focusState(_ id: String) -> Bool? { focus.map { $0 == id } }
    private func hover(_ id: String) -> (Bool) -> Void {
        { inside in if inside { focus = id } else if focus == id { focus = nil } }
    }
}

/// Recording, paused, armed or starting: a living dot, the state, and the time large.
private struct PanelRecordingStatus: View {
    @ObservedObject var model: RecordingStateModel
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 8) {
            if model.isStarting {
                ProgressView().controlSize(.small)
                Text("Preparing recording…").font(Theme.Font.bodyStrong)
            } else if model.isArmed {
                InkSymbol(name: "macwindow", pointSize: 14, canvas: 20).foregroundStyle(Theme.Palette.ink2.color)
                Text("Ready to start").font(Theme.Font.bodyStrong)
            } else {
                let recording = model.state == .recording
                ZStack {
                    Circle().fill(Theme.Palette.record.color.opacity(recording ? 0.35 : 0))
                        .frame(width: 16, height: 16)
                        .scaleEffect(pulse && recording && !reduceMotion ? 1.3 : 0.7)
                        .opacity(pulse && recording ? 0 : 1)
                    Circle().fill(recording ? Theme.Palette.record.color : Theme.Palette.ink3.color)
                        .frame(width: 9, height: 9)
                }
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { pulse = true }
                }
                Text(model.state == .paused ? "Paused" : "Recording").font(Theme.Font.bodyStrong)
            }
            Spacer(minLength: 0)
            if let elapsed = model.elapsed, model.state != .idle {
                Text(verbatim: elapsed)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced)).monospacedDigit()
                    .contentTransition(.numericText())
                    .accessibilityLabel(Text("Elapsed time"))
            }
        }
    }
}

/// A capsule choice: filled when selected; hovered, its symbol rises and glows and its
/// siblings step back, like every tool in the panel.
private struct PanelChip: View {
    let symbol: String
    let title: Text
    let selected: Bool
    let focus: Bool?
    let action: () -> Void
    let hover: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let lifted = focus == true
        Button(action: action) {
            HStack(spacing: 4) {
                InkSymbol(name: symbol, pointSize: 11, weight: .semibold, canvas: 16)
                    .scaleEffect(lifted && !reduceMotion ? 1.18 : 1)
                    .offset(y: lifted && !reduceMotion ? -1 : 0)
                    .shadow(color: Theme.Palette.ink.color.opacity(lifted ? 0.5 : 0), radius: 5)
                title.font(Theme.Font.captionStrong).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(selected ? Theme.Palette.selectionStrong.color : .clear, in: .capsule)
            .opacity(focus == false ? 0.5 : 1)
            .contentShape(.capsule)
        }
        .buttonStyle(PanelPressStyle())
        .onHover(perform: hover)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.62), value: focus)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PanelDeviceToggle: View {
    let title: LocalizedStringKey
    let symbol: String
    let on: Bool
    let available: Bool
    let focus: Bool?
    let action: () -> Void
    let hover: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let lifted = focus == true && available
        Button(action: action) {
            InkSymbol(name: on ? symbol + ".fill" : symbol + ".slash", pointSize: 13, weight: .semibold, canvas: 20)
                .foregroundStyle(on ? Theme.Palette.ink.color : Theme.Palette.ink3.color)
                .scaleEffect(lifted && !reduceMotion ? 1.18 : 1)
                .offset(y: lifted && !reduceMotion ? -1 : 0)
                .shadow(color: Theme.Palette.ink.color.opacity(lifted ? 0.5 : 0), radius: 5)
                .frame(width: 30, height: 28)
                .background(on ? Theme.Palette.selectionStrong.color : .clear, in: .capsule)
                .opacity(focus == false ? 0.5 : 1)
                .contentShape(.capsule)
        }
        .buttonStyle(PanelPressStyle())
        .disabled(!available)
        .onHover(perform: hover)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.62), value: focus)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(on ? "On" : "Off"))
        .help(Text(available ? on ? "Disable for the next recording" : "Enable for the next recording" : "Finish or cancel recording to change this setting"))
    }
}

private struct PanelRecordingControls: View {
    @ObservedObject var model: RecordingStateModel
    let context: PanelPresentation
    let actions: PanelActions
    var body: some View {
        HStack(spacing: 8) {
            if model.isArmed {
                PanelSecondaryButton(title: "Cancel", symbol: "xmark", action: actions.cancelArmed)
                    .keyboardShortcut(.cancelAction)
                PanelPrimaryButton(title: "Start", symbol: "record.circle", action: actions.toggleRecording)
            } else if model.isStarting {
                PanelPrimaryButton(title: "Preparing…", symbol: "hourglass", action: {}).disabled(true)
            } else if model.state != .idle {
                PanelSecondaryButton(title: model.state == .paused ? "Resume" : "Pause",
                                     symbol: model.state == .paused ? "play.fill" : "pause.fill", action: actions.pauseResume)
                PanelPrimaryButton(title: "Stop", symbol: "stop.fill", action: actions.toggleRecording)
            } else {
                PanelPrimaryButton(title: "Record", symbol: "record.circle",
                                   shortcut: KeyboardShortcuts.getShortcut(for: .toggleRecording)?.description,
                                   action: { context.startRecording(using: actions) })
            }
        }
        .frame(height: 40)
    }
}

/// The panel's call to action: a capsule that blooms on hover.
private struct PanelPrimaryButton: View {
    let title: LocalizedStringKey
    let symbol: String
    var shortcut: String?
    var tint: Color = Theme.Palette.record.color
    var onTint: Color = Theme.Palette.onRecord.color
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                    .scaleEffect(hovered && !reduceMotion ? 1.12 : 1)
                Text(title).font(Theme.Font.bodyStrong)
                if let shortcut, hovered {
                    Text(verbatim: shortcut).font(Theme.Font.dataSmall).opacity(0.75).transition(.opacity)
                }
            }
            .foregroundStyle(onTint)
            .frame(maxWidth: .infinity).frame(height: 40)
            .background(tint.opacity(enabled ? (hovered ? 1 : 0.92) : 0.5), in: .capsule)
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .shadow(color: tint.opacity(hovered ? 0.45 : 0), radius: 10, y: 2)
            .contentShape(.capsule)
        }
        .buttonStyle(PanelPressStyle())
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: hovered)
    }
}

/// The quieter partner of the primary button, with the same bloom in a softer key.
private struct PanelSecondaryButton: View {
    let title: LocalizedStringKey
    let symbol: String
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                    .scaleEffect(hovered && !reduceMotion ? 1.12 : 1)
                Text(title).font(Theme.Font.bodyStrong)
            }
            .frame(maxWidth: .infinity).frame(height: 40)
            .background(hovered ? Theme.Palette.pressed.color : Theme.Palette.hover.color, in: .capsule)
            .overlay(Capsule().strokeBorder(.white.opacity(hovered ? 0.18 : 0.08), lineWidth: 1))
            .shadow(color: Theme.Palette.ink.color.opacity(hovered ? 0.18 : 0), radius: 8, y: 1)
            .contentShape(.capsule)
        }
        .buttonStyle(PanelPressStyle())
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: hovered)
    }
}

/// Recent captures in a strip of tiles of one ratio (see `PanelRecentCarousel`); "All" opens the Library.
private struct PanelRecentCell: View {
    let items: [CaptureItem]
    let images: [String: CGImage]
    let loading: Bool
    let issue: String?
    let open: (CaptureItem) -> Void
    let showAll: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent captures").font(Theme.Font.captionStrong).foregroundStyle(Theme.Palette.ink3.color)
                Spacer()
                PanelLinkButton(title: "All", action: showAll)
            }
            .frame(height: 16)
            if items.isEmpty {
                Label(loading ? "Loading captures…" : issue == nil ? "No captures yet" : "Captures unavailable",
                      systemImage: loading ? "clock" : "photo")
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.ink3.color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .help(Text(verbatim: issue ?? ""))
            } else {
                PanelRecentCarousel(items: items, images: images, open: open)
                    .frame(height: PanelCarouselView.tile.height + 2)
            }
        }
        .padding(CapturePanelView.Layout.padding)
        .panelCell()
    }
}

/// A capture shown whole inside a frame of fixed size, over a muted blur of itself.
private struct PanelCaptureWell: View {
    let image: CGImage?
    let placeholder: String
    var playable = false
    var hovered = false
    let cornerRadius: CGFloat
    var body: some View {
        ZStack {
            Theme.Palette.well.color
            if let image {
                // The fill never sizes the well: it only covers the space the frame gives it.
                Color.clear.overlay {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                        .blur(radius: 12).saturation(0.75)
                }
                .clipped()
                Color.black.opacity(0.3)
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            } else {
                Image(systemName: placeholder).foregroundStyle(Theme.Palette.ink3.color)
            }
            if playable {
                Image(systemName: "play.fill")
                    .font(.system(size: hovered ? 15 : 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: hovered ? 36 : 28, height: hovered ? 36 : 28)
                    .background(.black.opacity(0.4), in: .circle)
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
            }
        }
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
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

private struct PanelLinkButton: View {
    let title: LocalizedStringKey
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text(title)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    .offset(x: hovered ? 2 : 0)
            }
            .font(Theme.Font.captionStrong)
            .foregroundStyle(hovered ? Theme.Palette.ink.color : Theme.Palette.ink2.color)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovered)
    }
}

/// Where else to go: the window, its modules, Settings, Quit. Hovering a destination names it
/// and says what it does on the left.
private struct PanelDestinationsCell: View {
    let actions: PanelActions
    @State private var focus: Destination?
    enum Destination: CaseIterable {
        case library, studio, edit, settings, quit
        var symbol: String {
            switch self {
            case .library: "rectangle.stack"
            case .studio: "video"
            case .edit: "scissors"
            case .settings: "gearshape"
            case .quit: "power"
            }
        }
        var title: LocalizedStringKey {
            switch self {
            case .library: "Library"
            case .studio: "Studio"
            case .edit: "Edit"
            case .settings: "Settings"
            case .quit: "Quit Camcord"
            }
        }
        var detail: LocalizedStringKey {
            switch self {
            case .library: "All your captures"
            case .studio: "Set up a recording"
            case .edit: "Mark up captures"
            case .settings: "Shortcuts and saving"
            case .quit: "Stops every shortcut"
            }
        }
    }
    var body: some View {
        HStack(spacing: 0) {
            Button(action: actions.openMainWindow) {
                HStack(spacing: 9) {
                    CamcordBrandMark().frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Group {
                            if let focus {
                                Text(focus.title).font(Theme.Font.captionStrong)
                                Text(focus.detail).font(Theme.Font.caption).foregroundStyle(Theme.Palette.ink3.color)
                            } else {
                                Text("Open Camcord").font(Theme.Font.captionStrong)
                                Text(verbatim: "⌘0").font(Theme.Font.dataSmall).foregroundStyle(Theme.Palette.ink3.color)
                            }
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    }
                    .id(focus.map { "\($0)" } ?? "home")
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 3)), removal: .opacity))
                }
                .contentShape(.rect)
            }
            .keyboardShortcut("0", modifiers: .command)
            .buttonStyle(PanelPressStyle())
            .accessibilityLabel(Text("Open Camcord"))
            Spacer(minLength: 6)
            ForEach(Destination.allCases, id: \.self) { destination in
                PanelIconButton(symbol: destination.symbol, title: destination.title,
                                focus: focus.map { $0 == destination }, action: perform(destination)) { inside in
                    if inside { focus = destination } else if focus == destination { focus = nil }
                }
            }
        }
        .animation(.easeOut(duration: 0.16), value: focus)
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .panelCell()
    }
    private func perform(_ destination: Destination) -> () -> Void {
        switch destination {
        case .library: actions.openLibrary
        case .studio: actions.openStudio
        case .edit: actions.openEditor
        case .settings: actions.openSettings
        case .quit: actions.quit
        }
    }
}

/// An icon-only tool button: the same rise and glow, and the same stepping back of its siblings.
private struct PanelIconButton: View {
    let symbol: String
    let title: LocalizedStringKey
    let focus: Bool?
    let action: () -> Void
    let hover: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let lifted = focus == true
        Button(action: action) {
            InkSymbol(name: symbol, pointSize: 14, canvas: 22)
                .frame(width: 30, height: 30)
                .scaleEffect(lifted && !reduceMotion ? 1.18 : 1)
                .offset(y: lifted && !reduceMotion ? -1.5 : 0)
                .shadow(color: Theme.Palette.ink.color.opacity(lifted ? 0.45 : 0), radius: 6)
                .opacity(focus == false ? 0.5 : 1)
                .contentShape(.rect)
        }
        .buttonStyle(PanelPressStyle())
        .onHover(perform: hover)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.62), value: focus)
        .accessibilityLabel(Text(title))
    }
}

/// Every panel button gives a little under the finger.
private struct PanelPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// The panel is the window tray: its light frost and the window's rim; the cells carry the glass.
private struct PanelTray: ViewModifier {
    @Environment(\.camcordOpaqueMaterialPreview) private var opaquePreview
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content
            .background {
                if opaquePreview || reduceTransparency {
                    RoundedRectangle(cornerRadius: CapturePanelView.cornerRadius, style: .continuous)
                        .fill(Theme.Palette.glassSolidChrome.color)
                } else {
                    TrayBlur(cornerRadius: CapturePanelView.cornerRadius)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: CapturePanelView.cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

// MARK: - Recording finished

private struct PanelFinishingCell: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Finalizing recording…").font(Theme.Font.body).foregroundStyle(Theme.Palette.ink2.color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .panelCell()
    }
}

/// The finished recording, large: its poster whole over a blur of itself, a name to rename it,
/// what it is, and the two things to do next, with the panel's bloom.
private struct PanelFinishedCell: View {
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
    @State private var previewHovered = false
    @State private var closeHovered = false

    init(url: URL, reveal: @escaping (URL) -> Void, open: @escaping (URL) -> Void,
         renamed: @escaping (URL) -> Void, dismiss: @escaping () -> Void) {
        self.reveal = reveal
        self.open = open
        self.renamed = renamed
        self.dismiss = dismiss
        _currentURL = State(initialValue: url)
        _name = State(initialValue: url.deletingPathExtension().lastPathComponent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(Theme.Palette.ok.color.opacity(0.16)).frame(width: 26, height: 26)
                        .scaleEffect(appeared ? 1 : 0.5)
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.Palette.ok.color)
                        .scaleEffect(appeared ? 1 : 0.2)
                }
                .opacity(appeared ? 1 : 0)
                Text("Recording ready").font(Theme.Font.bodyStrong)
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(closeHovered ? Theme.Palette.pressed.color : Theme.Palette.hover.color, in: .circle)
                        .contentShape(.circle)
                }
                .buttonStyle(PanelPressStyle())
                .onHover { closeHovered = $0 }
                .disabled(isRenaming)
                .help("Close")
                .accessibilityLabel("Close")
            }
            .frame(height: 28)

            Button { Task { await performAfterRename(open) } } label: {
                PanelCaptureWell(image: presentation?.poster, placeholder: "film", playable: presentation?.poster != nil,
                                 hovered: previewHovered, cornerRadius: 12)
                    .overlay {
                        if presentation == nil { ProgressView().controlSize(.small) }
                    }
                    .frame(height: 176)
                    .scaleEffect(previewHovered && !reduceMotion ? 1.015 : 1)
                    .shadow(color: .black.opacity(previewHovered ? 0.3 : 0.12), radius: previewHovered ? 10 : 4, y: 3)
            }
            .buttonStyle(PanelPressStyle())
            .onHover { previewHovered = $0 }
            .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.7), value: previewHovered)
            .accessibilityLabel("Recording preview")
            .accessibilityHint("Opens the recording")

            HStack(spacing: 4) {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.bodyStrong)
                    .disabled(isRenaming)
                    .onSubmit { Task { _ = await commitRename() } }
                Text("." + currentURL.pathExtension).font(Theme.Font.dataSmall).foregroundStyle(Theme.Palette.ink3.color)
                if isRenaming { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Theme.Palette.hover.color, in: .capsule)
            .help("Rename the recording")

            HStack(spacing: 12) {
                if let renameMessage {
                    Label(renameMessage, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(Theme.Palette.record.color).lineLimit(1)
                } else {
                    MetaLabel(symbol: "internaldrive", text: presentation?.size ?? "…")
                    MetaLabel(symbol: "clock", text: presentation?.duration ?? "…")
                    if let dims = presentation?.dimensions { MetaLabel(symbol: "rectangle.ratio.16.to.9", text: dims) }
                }
                Spacer(minLength: 0)
            }
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.ink3.color)
            .frame(height: 14)
            .help(Text(verbatim: currentURL.deletingLastPathComponent().path))

            HStack(spacing: 8) {
                PanelSecondaryButton(title: "Show in Finder", symbol: "folder") {
                    Task { await performAfterRename(reveal) }
                }
                PanelPrimaryButton(title: "Open", symbol: "play.fill", tint: Theme.Palette.ink.color, onTint: Theme.Palette.onInk.color) {
                    Task { await performAfterRename(open) }
                }
            }
            .frame(height: 40)
            .disabled(isRenaming)
        }
        .padding(CapturePanelView.Layout.padding)
        .panelCell()
        .onAppear {
            if reduceMotion { appeared = true }
            else { withAnimation(.spring(response: 0.42, dampingFraction: 0.6)) { appeared = true } }
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
            Image(systemName: symbol)
            Text(text).monospacedDigit()
        }
    }
}

/// Poster frame and metadata are loaded asynchronously from the actual completed file.
private struct RecordingPresentation: @unchecked Sendable {
    let poster: CGImage?
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
        generator.maximumSize = CGSize(width: 960, height: 600)
        let poster = try? await generator.image(at: previewTime).image
        return RecordingPresentation(
            poster: poster,
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

