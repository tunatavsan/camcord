import SwiftUI

/// The Design Lab's component page (RUN UI-2 P1.2): every kit component in all its states.
struct ComponentGallery: View {
    @State private var cameraOn = true
    @State private var micOn = true
    @State private var targetOn = true
    @State private var breath = 0
    @State private var snapped = false
    @State private var condensed = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xxl) {
                marks
                keys
                recordAndChips
                instruments
                states
                moments
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.Palette.window.color)
    }

    private var marks: some View {
        Specimen(title: "Viewfinder mark") {
            HStack(alignment: .bottom, spacing: Theme.Space.xl) {
                ForEach([14.0, 20, 32, 56, 72], id: \.self) { size in
                    ViewfinderMarkView(dot: .plain).frame(width: size, height: size)
                }
                ViewfinderMarkView(dot: .recording).frame(width: 32, height: 32)
                ViewfinderMarkView(dot: .none).frame(width: 32, height: 32)
                Image(nsImage: ViewfinderMarkView.templateImage(size: 18))
            }
            .foregroundStyle(Theme.Palette.ink.color)
        }
    }

    private var keys: some View {
        Specimen(title: "Capture keys · key caps · sidebar rows") {
            HStack(alignment: .top, spacing: Theme.Space.xxl) {
                InsetWell {
                    HStack(spacing: Theme.Space.xs) {
                        ForEach(CaptureKind.allCases) { kind in
                            Button {} label: { Label { Text(kind.shortTitle) } icon: { Image(systemName: kind.symbol) } }
                                .buttonStyle(WellKeyStyle())
                                .help(Text(kind.title))
                                .accessibilityLabel(Text(kind.actionTitle))
                        }
                    }
                }
                .frame(width: 296)
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(CaptureKind.allCases) { kind in
                        HStack(spacing: Theme.Space.s) {
                            Image(systemName: kind.symbol).frame(width: Theme.Space.xl).accessibilityHidden(true)
                            Text(kind.title).frame(width: 110, alignment: .leading)
                            KeyCap(shortcut: kind.shortcut)
                        }
                    }
                }
                .foregroundStyle(Theme.Palette.ink.color)
                List {
                    SidebarRow(title: "Library", symbol: "photo.on.rectangle", key: "⌘1")
                    SidebarRow(title: "Studio", symbol: "video.badge.waveform", key: "⌘2")
                    SidebarRow(title: "Edit", symbol: "scissors", tag: "Later", key: "⌘3")
                    SidebarRow(title: "Settings", symbol: "gearshape", key: "⌘4")
                }
                .listStyle(.sidebar)
                .frame(width: 230, height: 150)
            }
        }
    }

    private var recordAndChips: some View {
        Specimen(title: "Record · chips (system controls, token tints)") {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                HStack(spacing: Theme.Space.m) {
                    RecordButton(size: .toolbar) {}
                    RecordButton(size: .toolbar, isRecording: true) {}
                    RecordButton(size: .toolbar, isBusy: true) {}
                    RecordButton(size: .bar) {}.frame(width: 296)
                }
                HStack(spacing: Theme.Space.s) {
                    Chip(title: CaptureKind.window.title, symbol: "macwindow", isOn: $targetOn)
                    Chip(title: "Camera", symbol: "video.fill", offSymbol: "video.slash.fill", isOn: $cameraOn) {
                        RoundedRectangle(cornerRadius: Theme.Radius.badge - 1, style: .continuous)
                            .fill(Theme.Palette.well.color)
                            .frame(width: 22, height: 14)
                    }
                    Chip(title: "Mic", symbol: "mic.fill", offSymbol: "mic.slash.fill", isOn: $micOn) {
                        AudioLevelMeter(levels: AudioLevels(rmsDBFS: -14, peakDBFS: -8, limited: false),
                                        active: micOn, height: 4)
                            .frame(width: 24)
                    }
                }
                HStack(spacing: Theme.Space.s) {
                    Button("Capture a region") {}.buttonStyle(.borderedProminent).tint(Theme.Palette.ink.color).controlSize(.large)
                    Button("Open Camcord") {}.buttonStyle(.bordered).controlSize(.large)
                    Button("Done") {}.buttonStyle(.glass)
                    Button("Record again") {}.buttonStyle(.glassProminent).tint(Theme.Palette.record.color)
                }
            }
        }
    }

    private var instruments: some View {
        Specimen(title: "Meters · timecode · tally") {
            HStack(alignment: .center, spacing: Theme.Space.xxl) {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    ForEach([-40.0, -18, -9, -3], id: \.self) { db in
                        HStack(spacing: Theme.Space.m) {
                            Text(verbatim: "\(Int(db)) dB").font(Theme.Font.data).frame(width: 56, alignment: .trailing)
                            AudioLevelMeter(levels: AudioLevels(rmsDBFS: db, peakDBFS: db + 4, limited: false))
                                .frame(width: 200)
                        }
                    }
                    HStack(spacing: Theme.Space.m) {
                        Text("Off", comment: "Accessibility value: a meter that is not measuring")
                            .font(Theme.Font.data).frame(width: 56, alignment: .trailing)
                        AudioLevelMeter(levels: nil, active: false).frame(width: 200)
                    }
                }
                .foregroundStyle(Theme.Palette.ink2.color)
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    TimecodeLabel(seconds: 266, style: .display)
                    TimecodeLabel(seconds: 3866, style: .data)
                    TimecodeLabel(seconds: 266, style: .pill)
                        .padding(.horizontal, Theme.Space.s)
                        .padding(.vertical, 2)
                        .foregroundStyle(Theme.Palette.onRecord.color)
                        .background(Capsule().fill(Theme.Palette.record.color))
                }
                .foregroundStyle(Theme.Palette.ink.color)
                HStack(spacing: Theme.Space.l) {
                    TallyRing(seconds: 26).frame(width: 30, height: 30)
                    TallyRing(seconds: 266, paused: true).frame(width: 30, height: 30)
                    TallyRing(seconds: 45).frame(width: 44, height: 44)
                }
            }
        }
    }

    private var states: some View {
        Specimen(title: "Empty state") {
            EmptyState(title: "No captures yet") {
                HStack(spacing: Theme.Space.s) {
                    ForEach(CaptureKind.allCases) { kind in
                        VStack(spacing: Theme.Space.xs) {
                            Image(systemName: kind.symbol).accessibilityHidden(true)
                            Text(kind.title).font(Theme.Font.caption)
                            KeyCap(shortcut: kind.shortcut)
                        }
                        .frame(width: 92)
                    }
                }
            }
            .frame(height: 260)
        }
    }

    private var moments: some View {
        Specimen(title: "Condense · capture brackets · frost breath") {
            HStack(spacing: Theme.Space.xl) {
                ZStack {
                    Theme.Palette.well.color
                    if condensed {
                        Text(verbatim: "Copied")
                            .font(Theme.Font.bodyStrong)
                            .foregroundStyle(Theme.Palette.ink.color)
                            .padding(.horizontal, Theme.Space.l)
                            .padding(.vertical, Theme.Space.s)
                            .camcordGlass(.chrome, in: Capsule())
                            .transition(CondenseTransition(reduceMotion: reduceMotion))
                    }
                }
                .frame(width: 200, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.box, style: .continuous))
                ZStack {
                    LinearGradient(colors: [Theme.Palette.ink2.color, Theme.Palette.raised.color],
                                   startPoint: .top, endPoint: .bottom)
                    FrostBreath(trigger: breath)
                    CaptureBrackets(inset: snapped ? 0 : -18)
                        .stroke(Theme.Palette.ink.color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .padding(Theme.Space.l)
                }
                .frame(width: 280, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.box, style: .continuous))
                Button {
                    withAnimation(Theme.Motion.resolve(Theme.Motion.panel, reduceMotion: reduceMotion)) { condensed.toggle() }
                    withAnimation(Theme.Motion.resolve(Theme.Motion.snap, reduceMotion: reduceMotion)) { snapped.toggle() }
                    breath += 1
                } label: {
                    Text(verbatim: "Play")
                }
            }
        }
    }
}

private struct Specimen<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(verbatim: title)
                .font(Theme.Font.captionStrong)
                .tracking(Theme.Font.headerTracking)
                .foregroundStyle(Theme.Palette.ink3.color)
            content
        }
    }
}
