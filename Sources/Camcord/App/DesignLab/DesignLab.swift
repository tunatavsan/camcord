import AppKit
import QuartzCore
import SwiftUI

// A hidden Design Lab that renders four specimens — the recording hub, a camera tile, a panel
// card and a sidebar row — in REAL Liquid Glass, with blur-motion, in each design direction's
// key tokens. Its job is to prove (or disprove) that native can match the directions' HTML
// prototypes. Opened from the status menu with ⌥ held.

/// One design direction's key tokens, as far as the four specimens need them.
struct LabDirection: Identifiable, Hashable {
    let id: String
    let name: String
    let accent: Color
    /// Glass variant and the colour it is tinted toward (nil = untinted).
    let clearGlass: Bool
    let glassTint: Color?
    /// Corner radii: floating surfaces and controls.
    let surfaceRadius: CGFloat
    let controlRadius: CGFloat
    /// Base spacing unit: density.
    let spacing: CGFloat
    /// Motion personality: the morph spring and the blur a surface arrives from.
    let morph: Animation
    let arrivalBlur: CGFloat
    let arrivalScale: CGFloat
    /// The backdrop the glass sits over.
    let backdrop: [Color]
    let prefersDark: Bool

    var glass: Glass {
        let base: Glass = clearGlass ? .clear : .regular
        return glassTint.map { base.tint($0) } ?? base
    }

    static func == (lhs: LabDirection, rhs: LabDirection) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Frame pacing while something animates: display-link intervals over a short window after
/// each interaction. Headless or behind a locked screen the link does not fire, and the meter
/// says so instead of inventing a number.
@MainActor
final class FrameMeter: ObservableObject {
    @Published private(set) var summary = "—"
    private var link: CADisplayLink?
    private var proxy: FrameMeterProxy?
    private var last: CFTimeInterval?
    private var intervals: [CFTimeInterval] = []
    private var stopAt: CFTimeInterval = 0
    private var expected: CFTimeInterval = 1.0 / 60

    func measure(on view: NSView, for seconds: CFTimeInterval = 1.2) {
        stopAt = CACurrentMediaTime() + seconds
        guard link == nil else { return }
        intervals.removeAll()
        last = nil
        let proxy = FrameMeterProxy(meter: self)
        let link = view.displayLink(target: proxy, selector: #selector(FrameMeterProxy.tick(_:)))
        let fps = Float(view.window?.screen?.maximumFramesPerSecond ?? 60)
        expected = 1.0 / Double(fps)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: fps, preferred: fps)
        link.add(to: .main, forMode: .common)
        self.link = link
        self.proxy = proxy
        summary = "measuring…"
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds + 0.3))
            self?.finishIfIdle()
        }
    }

    fileprivate func tick(_ link: CADisplayLink) {
        if let last { intervals.append(link.timestamp - last) }
        last = link.timestamp
        if link.timestamp >= stopAt { finish() }
    }

    private func finishIfIdle() {
        guard link != nil, CACurrentMediaTime() >= stopAt else { return }
        finish()
    }

    private func finish() {
        link?.invalidate()
        link = nil
        proxy = nil
        guard !intervals.isEmpty else {
            summary = "UNMEASURED: no display frames (screen locked or window hidden)"
            DiagnosticsLog.append("design-lab frames=0")
            return
        }
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        let worst = intervals.max() ?? 0
        let hitches = intervals.filter { $0 > expected * 1.5 }.count
        summary = String(format: "%d frames · avg %.0f fps · worst %.1f ms · %d hitches",
                         intervals.count, 1 / mean, worst * 1000, hitches)
        DiagnosticsLog.append("design-lab \(summary)")
    }
}

private final class FrameMeterProxy: NSObject {
    private weak var meter: FrameMeter?
    init(meter: FrameMeter) { self.meter = meter }
    @MainActor @objc func tick(_ link: CADisplayLink) { meter?.tick(link) }
}

struct DesignLabView: View {
    let directions: [LabDirection]
    @State private var selected: LabDirection
    @State private var hubOpen = false
    @State private var panelShown = true
    @State private var sidebarRow = 0
    @State private var tileWidth: CGFloat = 260
    @StateObject private var meter = FrameMeter()
    @State private var host = NSView()
    @Namespace private var glassSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(directions: [LabDirection]) {
        self.directions = directions
        _selected = State(initialValue: directions[0])
    }

    private var motion: Animation { reduceMotion ? .easeInOut(duration: 0.15) : selected.morph }

    private func animate(_ change: () -> Void) {
        meter.measure(on: host)
        withAnimation(motion, change)
    }

    var body: some View {
        ZStack {
            LabBackdrop(colors: selected.backdrop)
            VStack(alignment: .leading, spacing: selected.spacing * 2) {
                header
                HStack(alignment: .top, spacing: selected.spacing * 3) {
                    VStack(alignment: .leading, spacing: selected.spacing * 3) {
                        specimen("Hub") { hub }
                        specimen("Camera tile") { tile }
                    }
                    specimen("Panel card") { panel }
                    specimen("Sidebar row") { sidebar }
                }
                Spacer(minLength: 0)
            }
            .padding(selected.spacing * 3)
            HostView(view: host).frame(width: 1, height: 1).opacity(0)
        }
        .tint(selected.accent)
        .preferredColorScheme(selected.prefersDark ? .dark : .light)
        .frame(minWidth: 1080, minHeight: 700)
    }

    private var header: some View {
        HStack(spacing: selected.spacing * 2) {
            Picker(selection: $selected) {
                ForEach(directions) { Text($0.name).tag($0) }
            } label: {
                Text(verbatim: "Direction")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 480)
            .onChange(of: selected) { _, _ in meter.measure(on: host) }
            Spacer()
            Text(verbatim: "Frame pacing: \(meter.summary)")
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .glassEffect(.regular, in: Capsule())
            Text(verbatim: reduceMotion ? "Reduce Motion: on" : "Reduce Motion: off")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func specimen<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: selected.spacing) {
            Text(verbatim: title.uppercased())
                .font(.system(size: 10, weight: .semibold)).kerning(0.8)
                .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: Specimens

    /// The disc that morphs into a capsule: one glass shape per state sharing an id, in a
    /// container, so the change is Liquid Glass's own morph rather than a resize.
    private var hub: some View {
        GlassEffectContainer(spacing: selected.spacing * 2) {
            Group {
                if hubOpen {
                    HStack(spacing: selected.spacing * 2) {
                        Image(systemName: "pause.fill")
                        Image(systemName: "stop.fill").foregroundStyle(.red)
                        VStack(spacing: 1) {
                            Circle().fill(.red).frame(width: 6, height: 6)
                            Text(verbatim: "1:24").font(.system(size: 11, weight: .semibold).monospacedDigit())
                        }
                        Image(systemName: "eye")
                        Image(systemName: "mic.fill")
                    }
                    .padding(.horizontal, selected.spacing * 2)
                    .frame(height: 44)
                    .glassEffect(selected.glass.interactive(), in: Capsule())
                    .glassEffectID("hub", in: glassSpace)
                } else {
                    VStack(spacing: 1) {
                        Circle().fill(.red).frame(width: 6, height: 6)
                        Text(verbatim: "1:24").font(.system(size: 11, weight: .semibold).monospacedDigit())
                    }
                    .frame(width: 44, height: 44)
                    .glassEffect(selected.glass.interactive(), in: Circle())
                    .glassEffectID("hub", in: glassSpace)
                }
            }
        }
        .frame(width: 260, height: 60, alignment: .center)
        .contentShape(Rectangle())
        .onHover { inside in animate { hubOpen = inside } }
        .onTapGesture { animate { hubOpen.toggle() } }
        .accessibilityLabel(Text(verbatim: "Recording hub"))
    }

    /// The camera tile: video, the one-device-pixel specular hairline and a lift.
    private var tile: some View {
        VStack(alignment: .leading, spacing: selected.spacing) {
            let height = tileWidth * 9 / 16
            let radius = min(tileWidth, height) * 0.10
            ZStack {
                LinearGradient(colors: [.indigo, .teal, .orange.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "person.crop.circle.fill").font(.system(size: height * 0.45)).foregroundStyle(.white.opacity(0.85))
            }
            .frame(width: tileWidth, height: height)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.10)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing),
                                  lineWidth: 1 / (NSScreen.main?.backingScaleFactor ?? 2))
            }
            .shadow(color: .black.opacity(0.35), radius: min(tileWidth * 0.5625 / 10, 24), y: min(tileWidth * 0.5625 / 30, 8))
            Slider(value: $tileWidth, in: 140...360).frame(width: 220)
                .accessibilityLabel(Text(verbatim: "Tile size"))
        }
    }

    /// The panel card: glass surface, glass buttons, and the blur-motion arrival.
    private var panel: some View {
        VStack(alignment: .leading, spacing: selected.spacing * 2) {
            Button { animate { panelShown.toggle() } } label: { Text(verbatim: panelShown ? "Hide panel" : "Show panel") }
                .buttonStyle(.glass)
            if panelShown {
                VStack(alignment: .leading, spacing: selected.spacing * 1.5) {
                    Text(verbatim: "Camcord").font(.system(size: 15, weight: .semibold))
                    HStack(spacing: selected.spacing) {
                        ForEach(["rectangle.dashed", "macwindow", "display", "arrow.down.to.line", "text.viewfinder"], id: \.self) { symbol in
                            Button {} label: { Image(systemName: symbol).frame(width: 30, height: 26) }
                                .buttonStyle(.glass)
                        }
                    }
                    HStack(spacing: selected.spacing) {
                        Label { Text(verbatim: "Window") } icon: { Image(systemName: "macwindow") }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .glassEffect(selected.glass, in: RoundedRectangle(cornerRadius: selected.controlRadius, style: .continuous))
                        Spacer()
                        Button {} label: { Label { Text(verbatim: "Record") } icon: { Image(systemName: "record.circle") } }
                            .buttonStyle(.glassProminent)
                    }
                }
                .padding(selected.spacing * 2)
                .frame(width: 300)
                .glassEffect(selected.glass, in: RoundedRectangle(cornerRadius: selected.surfaceRadius, style: .continuous))
                .transition(reduceMotion ? .opacity : .blurArrival(radius: selected.arrivalBlur, scale: selected.arrivalScale))
            }
        }
        .frame(width: 320, alignment: .topLeading)
    }

    /// A sidebar whose selection is a glass capsule that travels between rows.
    private var sidebar: some View {
        GlassEffectContainer {
            VStack(alignment: .leading, spacing: selected.spacing / 2) {
                ForEach(Array(["Library", "Studio", "Edit", "Settings"].enumerated()), id: \.offset) { index, title in
                    HStack {
                        Image(systemName: ["photo.stack", "video.badge.waveform", "scissors", "gearshape"][index])
                            .frame(width: 18)
                        Text(verbatim: title)
                        Spacer()
                    }
                    .padding(.horizontal, selected.spacing * 1.5)
                    .frame(height: 30)
                    .background {
                        if sidebarRow == index {
                            Color.clear
                                .glassEffect(selected.glass.tint(selected.accent.opacity(0.35)),
                                             in: RoundedRectangle(cornerRadius: selected.controlRadius, style: .continuous))
                                .glassEffectID("selection", in: glassSpace)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { animate { sidebarRow = index } }
                }
            }
            .padding(selected.spacing)
            .frame(width: 220)
            .glassEffect(selected.glass, in: RoundedRectangle(cornerRadius: selected.surfaceRadius, style: .continuous))
        }
    }
}

/// Blur + scale + opacity: the surface arrives out of focus and settles.
private struct BlurArrival: ViewModifier {
    let blur: CGFloat
    let scale: CGFloat
    let opacity: Double
    func body(content: Content) -> some View {
        content.blur(radius: blur).scaleEffect(scale, anchor: .top).opacity(opacity)
    }
}

extension AnyTransition {
    static func blurArrival(radius: CGFloat, scale: CGFloat) -> AnyTransition {
        .modifier(active: BlurArrival(blur: radius, scale: scale, opacity: 0),
                  identity: BlurArrival(blur: 0, scale: 1, opacity: 1))
    }
}

/// A desktop for the glass to refract: a wash of colour and two fake windows with text.
private struct LabBackdrop: View {
    let colors: [Color]
    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            ForEach(0..<2, id: \.self) { index in
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(0..<9, id: \.self) { line in
                        Text(verbatim: line % 3 == 0 ? "func capture(region: CGRect) async throws -> CGImage" : "let frame = stream.nextFrame() // \(line)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.7))
                    }
                }
                .padding(18)
                .frame(width: 520, height: 260, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor).opacity(0.85)))
                .offset(x: index == 0 ? 60 : 480, y: index == 0 ? 120 : 360)
            }
        }
        .ignoresSafeArea()
    }
}

/// Gives the frame meter an NSView in the window to hang its display link on.
private struct HostView: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The Lab's pages: the token and component galleries, and the design-direction specimens.
enum DesignLabPage: String, CaseIterable, Identifiable {
    case tokens, components, directions
    var id: String { rawValue }
}

@MainActor @Observable
final class DesignLabState {
    var page: DesignLabPage = .tokens
}

struct DesignLabRoot: View {
    @Bindable var state: DesignLabState

    var body: some View {
        VStack(spacing: 0) {
            Picker(selection: $state.page) {
                ForEach(DesignLabPage.allCases) { Text(verbatim: $0.rawValue.capitalized).tag($0) }
            } label: {
                Text(verbatim: "Page")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, Theme.Space.xxl)
            .padding(.bottom, Theme.Space.m)
            switch state.page {
            case .tokens: TokenGallery()
            case .components: ComponentGallery()
            case .directions: DesignLabView(directions: LabDirection.all)
            }
        }
        .background(Theme.Palette.window.color)
        .frame(minWidth: 1080, minHeight: 700)
    }
}

/// The Design Lab's window. Hidden: reached from the status menu with ⌥ held.
@MainActor
final class DesignLabWindowController {
    private var window: NSWindow?
    let state = DesignLabState()

    var windowForTesting: NSWindow? { window }

    /// `activate: false` (LiveCheck) puts the window behind the user's windows, without focus.
    func show(page: DesignLabPage? = nil, activate: Bool = true) {
        if let page { state.page = page }
        let window = window ?? {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Design Lab"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: DesignLabRoot(state: state))
            window.center()
            window.setFrameAutosaveName("CamcordDesignLab")
            return window
        }()
        self.window = window
        if activate {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderBack(nil)
        }
    }

    func close() { window?.close() }
}
