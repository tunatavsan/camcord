import SwiftUI

/// The Design Lab's token page (RUN UI-2 P1.1): every colour token in its four variants side by
/// side, then type, spacing, radii, motion and the glass styles in the window's own appearance.
struct TokenGallery: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xxl) {
                colours
                type
                spacingAndRadii
                motion
                glass
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.Palette.window.color)
    }

    // MARK: Colour

    private var colours: some View {
        LabSection(title: "Colour") {
            Grid(alignment: .leading, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.s) {
                GridRow {
                    Text(verbatim: "token")
                    ForEach(ThemeColor.Variant.allCases, id: \.self) { Text(verbatim: $0.rawValue) }
                }
                .font(Theme.Font.captionStrong)
                .foregroundStyle(Theme.Palette.ink3.color)
                ForEach(Theme.Palette.all, id: \.name) { token in
                    GridRow {
                        Text(verbatim: token.name)
                            .font(Theme.Font.data)
                            .foregroundStyle(Theme.Palette.ink.color)
                        ForEach(ThemeColor.Variant.allCases, id: \.self) { variant in
                            Swatch(value: token.value(variant), variant: variant)
                        }
                    }
                }
            }
        }
    }

    // MARK: Type

    private var type: some View {
        LabSection(title: "Type") {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                TypeSample(name: "display 30", font: Theme.Font.display, text: "Library", tracking: Theme.Font.displayTracking)
                TypeSample(name: "timecode 30", font: Theme.Font.timecode, text: "00:04:26")
                TypeSample(name: "title 20", font: Theme.Font.title, text: "No captures yet")
                TypeSample(name: "row 15", font: Theme.Font.row, text: "Scroll capture")
                TypeSample(name: "body 13", font: Theme.Font.body, text: "Keep copied captures in the Library")
                TypeSample(name: "caption 11", font: Theme.Font.captionStrong, text: "Screenshot", tracking: Theme.Font.headerTracking)
                TypeSample(name: "data 12", font: Theme.Font.data, text: "2560 × 1440 · 60 fps · −18 dB · 412 MB")
                TypeSample(name: "dataSmall 11", font: Theme.Font.dataSmall, text: "14:31 · 1.9 MB")
            }
        }
    }

    // MARK: Spacing and radii

    private var spacingAndRadii: some View {
        HStack(alignment: .top, spacing: Theme.Space.xxl) {
            LabSection(title: "Spacing") {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(Self.spaces, id: \.0) { name, value in
                        HStack(spacing: Theme.Space.m) {
                            Text(verbatim: "\(name) \(Int(value))").font(Theme.Font.data).frame(width: 64, alignment: .leading)
                            Rectangle().fill(Theme.Palette.ink2.color).frame(width: value * 4, height: Theme.Space.s)
                        }
                    }
                }
                .foregroundStyle(Theme.Palette.ink.color)
            }
            LabSection(title: "Radii (concentric)") {
                HStack(alignment: .bottom, spacing: Theme.Space.l) {
                    ForEach(Self.radii, id: \.0) { name, value in
                        VStack(spacing: Theme.Space.xs) {
                            RoundedRectangle(cornerRadius: value, style: .continuous)
                                .fill(Theme.Palette.raised.color)
                                .overlay(RoundedRectangle(cornerRadius: value, style: .continuous)
                                    .strokeBorder(Theme.Palette.hairlineStrong.color))
                                .frame(width: 56, height: 40)
                            Text(verbatim: "\(name) \(Int(value))").font(Theme.Font.dataSmall)
                                .foregroundStyle(Theme.Palette.ink2.color)
                        }
                    }
                }
            }
        }
    }

    private static let spaces: [(String, CGFloat)] = [
        ("xs", Theme.Space.xs), ("s", Theme.Space.s), ("m", Theme.Space.m),
        ("l", Theme.Space.l), ("xl", Theme.Space.xl), ("xxl", Theme.Space.xxl),
    ]
    private static let radii: [(String, CGFloat)] = [
        ("floating", Theme.Radius.floating), ("box", Theme.Radius.box), ("well", Theme.Radius.well),
        ("thumb", Theme.Radius.thumb), ("control", Theme.Radius.control), ("key", Theme.Radius.key),
        ("badge", Theme.Radius.badge),
    ]

    // MARK: Motion

    private var motion: some View {
        LabSection(title: "Motion") {
            MotionSamples()
        }
    }

    // MARK: Glass

    private var glass: some View {
        LabSection(title: "Glass (system Liquid Glass, token tints)") {
            ZStack {
                LinearGradient(colors: [Theme.Palette.record.color, Theme.Palette.ok.color, Theme.Palette.ink2.color],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                HStack(spacing: Theme.Space.xl) {
                    ForEach(GlassStyle.allCases, id: \.self) { style in
                        Text(verbatim: "\(style)")
                            .font(Theme.Font.bodyStrong)
                            .foregroundStyle(Theme.Palette.ink.color)
                            .padding(.horizontal, Theme.Space.xl)
                            .padding(.vertical, Theme.Space.l)
                            .camcordGlass(style, in: RoundedRectangle(cornerRadius: Theme.Radius.floating, style: .continuous))
                    }
                }
            }
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.box, style: .continuous))
        }
    }
}

private struct LabSection<Content: View>: View {
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

private struct Swatch: View {
    let value: ThemeColor.RGBA
    let variant: ThemeColor.Variant

    /// Each swatch sits on its own variant's window colour, so translucent tokens read true.
    private var ground: ThemeColor.RGBA { Theme.Palette.window.value(variant) }
    private var inkOnGround: ThemeColor.RGBA { Theme.Palette.ink.value(variant) }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                .fill(Color(nsColor: value.nsColor))
                .frame(width: Theme.Space.xl, height: Theme.Space.l)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                    .strokeBorder(Color(nsColor: inkOnGround.nsColor).opacity(0.25)))
            Text(verbatim: value.hexString)
                .font(Theme.Font.dataSmall)
                .foregroundStyle(Color(nsColor: inkOnGround.nsColor))
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.xs)
        .frame(width: 150, alignment: .leading)
        .background(Color(nsColor: ground.nsColor), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}

private struct TypeSample: View {
    let name: String
    let font: Font
    let text: String
    var tracking: CGFloat = 0

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.l) {
            Text(verbatim: name)
                .font(Theme.Font.dataSmall)
                .foregroundStyle(Theme.Palette.ink3.color)
                .frame(width: 96, alignment: .leading)
            Text(verbatim: text)
                .font(font)
                .tracking(tracking)
                .foregroundStyle(Theme.Palette.ink.color)
        }
    }
}

/// Each motion token moves a dot across a track when pressed; Reduce Motion cross-fades.
private struct MotionSamples: View {
    @State private var flipped = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let samples: [(String, Animation, Double)] = [
        ("instant", Theme.Motion.instant, Theme.Motion.Duration.instant),
        ("fast", Theme.Motion.fast, Theme.Motion.Duration.fast),
        ("panel", Theme.Motion.panel, Theme.Motion.Duration.panel),
        ("morph", Theme.Motion.morph, Theme.Motion.Duration.morph),
        ("exit", Theme.Motion.exit, Theme.Motion.Duration.exit),
        ("switch", Theme.Motion.moduleSwitch, Theme.Motion.Duration.moduleSwitch),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ForEach(Self.samples, id: \.0) { name, animation, seconds in
                HStack(spacing: Theme.Space.m) {
                    Text(verbatim: "\(name) \(String(format: "%.2f", seconds)) s")
                        .font(Theme.Font.data)
                        .foregroundStyle(Theme.Palette.ink.color)
                        .frame(width: 140, alignment: .leading)
                    Capsule().fill(Theme.Palette.raised.color).frame(width: 240, height: Theme.Space.s)
                        .overlay(alignment: flipped ? .trailing : .leading) {
                            Circle().fill(Theme.Palette.ink.color).frame(width: Theme.Space.m, height: Theme.Space.m)
                                .animation(Theme.Motion.resolve(animation, reduceMotion: reduceMotion), value: flipped)
                        }
                }
            }
            Button {
                flipped.toggle()
            } label: {
                Text(verbatim: "Play")
            }
        }
    }
}
