import SwiftUI

// Console's instrument details (K1): the running timecode and the tally with its seconds sweep.

/// Elapsed time as a recorder shows it: mm:ss under an hour, h:mm:ss above.
enum Timecode {
    static func format(_ seconds: Double) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        let (hours, minutes, secs) = (total / 3600, (total / 60) % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    /// "4 minutes, 26 seconds" for VoiceOver, in the user's language.
    static func spoken(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter.string(from: max(0, seconds.isFinite ? seconds : 0)) ?? format(seconds)
    }

    /// Where the tally's seconds sweep stands: 0 at the top of each minute, 1 at its end.
    static func sweep(_ seconds: Double) -> Double {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return seconds.truncatingRemainder(dividingBy: 60) / 60
    }
}

/// The running timecode, in SF Mono tabular digits.
struct TimecodeLabel: View {
    enum Style { case display, data, pill }
    let seconds: Double
    var style: Style = .data

    var body: some View {
        Text(verbatim: Timecode.format(seconds))
            .font(style == .display ? Theme.Font.timecode : style == .pill ? Theme.Font.dataStrong : Theme.Font.data)
            .contentTransition(.numericText())
            .accessibilityLabel(Text(verbatim: Timecode.spoken(seconds)))
    }
}

/// The record tally: a red dot inside a ring that sweeps once a minute. Paused, the dot is a
/// hollow ring and the sweep stops (state by shape, not colour alone).
struct TallyRing: View {
    let seconds: Double
    var paused = false

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let line = max(1.5, side * 0.08)
            ZStack {
                Circle().stroke(Theme.Palette.hairlineStrong.color, lineWidth: line)
                Circle()
                    .trim(from: 0, to: Timecode.sweep(seconds))
                    .stroke(Theme.Palette.record.color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Group {
                    if paused {
                        Circle().strokeBorder(Theme.Palette.record.color, lineWidth: line)
                    } else {
                        Circle().fill(Theme.Palette.record.color)
                    }
                }
                .padding(side * 0.28)
            }
            .padding(line / 2)
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// An empty state the system way (`ContentUnavailableView`) with the mark as its glyph.
struct EmptyState<Actions: View>: View {
    let title: LocalizedStringResource
    var message: LocalizedStringResource?
    @ViewBuilder var actions: Actions

    var body: some View {
        ContentUnavailableView {
            VStack(spacing: Theme.Space.m) {
                ViewfinderMarkView(dot: .plain)
                    .foregroundStyle(Theme.Palette.ink3.color)
                    .frame(width: 56, height: 56)
                Text(title).font(Theme.Font.title)
            }
        } description: {
            if let message { Text(message) }
        } actions: {
            actions
        }
    }
}

// MARK: - Motion pieces

/// Frost's condense (SPEC §2.5): a small surface arrives from a blur and 96 % scale. Reduce
/// Motion gets a plain fade.
struct CondenseTransition: Transition {
    var reduceMotion = false

    static func values(identity: Bool, reduceMotion: Bool) -> (opacity: Double, scale: CGFloat, blur: CGFloat) {
        if identity { return (1, 1, 0) }
        return reduceMotion ? (0, 1, 0) : (0, Theme.Motion.condenseScale, Theme.Motion.condenseBlur)
    }

    func body(content: Content, phase: TransitionPhase) -> some View {
        let value = Self.values(identity: phase.isIdentity, reduceMotion: reduceMotion)
        content
            .opacity(value.opacity)
            .scaleEffect(value.scale)
            .blur(radius: value.blur)
    }
}

/// Four brackets around a rect, `inset` points outside it (negative = inside). The capture
/// moment animates the inset from −18 to 0: the brackets snap onto what was captured.
struct CaptureBrackets: Shape {
    var inset: CGFloat
    var arm: CGFloat = 22

    var animatableData: CGFloat {
        get { inset }
        set { inset = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let frame = rect.insetBy(dx: -inset, dy: -inset)
        let length = max(0, min(arm, frame.width / 3, frame.height / 3))
        return ViewfinderMark.brackets(in: frame, arm: length, corner: min(8, length / 2))
    }
}

/// The capture moment's frost breath (K1): a pane of system glass over the captured rect frosts
/// and clears once per `trigger`, instead of a white flash. Reduce Motion: no breath at all.
struct FrostBreath: View {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let hidden = reduceMotion
        Rectangle()
            .fill(.clear)
            .camcordGlass(.chrome, in: Rectangle())
            .keyframeAnimator(initialValue: 0.0, trigger: trigger) { content, opacity in
                content.opacity(hidden ? 0 : opacity)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(1.0, duration: Theme.Motion.Duration.breath * 0.35)
                    CubicKeyframe(0.0, duration: Theme.Motion.Duration.breath * 0.65)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A sidebar row: the module's label, an optional tag ("Later") and its ⌘ key.
struct SidebarRow: View {
    let title: LocalizedStringResource
    let symbol: String
    var tag: LocalizedStringResource?
    var key: String?

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Label { Text(title) } icon: { Image(systemName: symbol) }
            Spacer(minLength: Theme.Space.xs)
            if let tag {
                Text(tag)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.ink3.color)
                    .padding(.horizontal, Theme.Space.s - 2)
                    .padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(Theme.Palette.hairlineStrong.color))
            }
            if let key {
                Text(verbatim: key)
                    .font(Theme.Font.dataSmall)
                    .foregroundStyle(Theme.Palette.ink3.color)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
