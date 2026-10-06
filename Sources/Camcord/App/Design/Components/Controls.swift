import KeyboardShortcuts
import SwiftUI

// System controls wearing Camcord's tokens: the system draws them, the tokens tint them.
// Record is the one strong colour; "on" states are ink, never the system accent.

/// Record / Stop. Always the system's prominent bordered button, tinted record red.
struct RecordButton: View {
    enum Size { case toolbar, bar, big }

    var size: Size = .toolbar
    var isRecording = false
    var isBusy = false
    let action: () -> Void

    private var title: LocalizedStringResource {
        isRecording
            ? LocalizedStringResource("Stop", comment: "Button: stop the recording")
            : LocalizedStringResource("Record", comment: "Button: start a recording")
    }

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
                    .font(size == .toolbar ? Theme.Font.body.weight(.semibold) : Theme.Font.rowStrong)
            } icon: {
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: isRecording ? "stop.fill" : "record.circle")
                }
            }
            .frame(maxWidth: size == .toolbar ? nil : .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(size == .toolbar ? .capsule : .roundedRectangle(radius: Theme.Radius.well))
        .controlSize(size == .toolbar ? .regular : .extraLarge)
        .tint(Theme.Palette.record.color)
        .disabled(isBusy)
        .accessibilityLabel(Text(isRecording
            ? LocalizedStringResource("Stop recording", comment: "Accessibility: the Stop button")
            : LocalizedStringResource("Start recording", comment: "Accessibility: the Record button")))
    }
}

/// A capsule chip: the system's bordered toggle button, so on/off is the system's own pressed
/// look, tinted ink. `accessory` carries a camera thumbnail or a live level.
struct Chip<Accessory: View>: View {
    let title: LocalizedStringResource
    let symbol: String
    var offSymbol: String?
    @Binding var isOn: Bool
    @ViewBuilder var accessory: Accessory

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: Theme.Space.s - 2) {
                // A thumbnail or a level is decoration here: the chip reads as its title and
                // the system toggle's own on/off state.
                accessory.accessibilityHidden(true)
                Image(systemName: isOn ? symbol : (offSymbol ?? symbol))
                Text(title).lineLimit(1)
            }
        }
        .toggleStyle(.button)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(Theme.Palette.ink.color)
    }
}

extension Chip where Accessory == EmptyView {
    init(title: LocalizedStringResource, symbol: String, offSymbol: String? = nil, isOn: Binding<Bool>) {
        self.init(title: title, symbol: symbol, offSymbol: offSymbol, isOn: isOn) { EmptyView() }
    }
}

/// A hotkey shown as a key cap ("⇧⌘2"), or "Not set".
struct KeyCap: View {
    let shortcut: KeyboardShortcuts.Shortcut?

    var body: some View {
        Group {
            if let shortcut {
                Text(verbatim: shortcut.description)
            } else {
                Text("Not set", comment: "A capture with no keyboard shortcut assigned")
            }
        }
        .font(Theme.Font.data)
        .foregroundStyle(Theme.Palette.ink.color)
        .padding(.horizontal, Theme.Space.s - 2)
        .padding(.vertical, 2)
        .background {
            // A key's lower edge is a second cap one point down, not a shadow.
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                    .fill(Theme.Palette.hairlineStrong.color)
                    .offset(y: 1)
                RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                    .fill(Theme.Palette.window.color)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                        .strokeBorder(Theme.Palette.hairline.color))
            }
        }
    }
}

/// A key in the menu-bar panel's well: icon over a short label, the system's plain button with
/// a hover and press fill (like Control Center's tiles).
struct WellKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WellKey(configuration: configuration)
    }

    private struct WellKey: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .labelStyle(StackedLabelStyle())
                .frame(maxWidth: .infinity, minHeight: 56)
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous))
                .background {
                    RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous)
                        .fill(configuration.isPressed ? Theme.Palette.pressed.color
                              : hovering ? Theme.Palette.hover.color : .clear)
                }
                .foregroundStyle(isEnabled ? Theme.Palette.ink.color : Theme.Palette.ink3.color)
                .onHover { hovering = $0 }
        }
    }
}

/// Icon over title, centred: the panel keys and the empty Library's key caps.
struct StackedLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: Theme.Space.xs + 1) {
            configuration.icon.font(Theme.Font.title.weight(.regular)).imageScale(.medium)
            configuration.title.font(Theme.Font.caption).lineLimit(1).minimumScaleFactor(0.85)
        }
    }
}

/// A small section title (the panel's "Screenshot" / "Record").
struct SectionHeader: View {
    let title: LocalizedStringResource

    var body: some View {
        Text(title)
            .font(Theme.Font.captionStrong)
            .tracking(Theme.Font.headerTracking)
            .foregroundStyle(Theme.Palette.ink3.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// An inset well inside a glass surface: a concentric recess, not a second glass.
struct InsetWell<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Theme.Space.xs)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.well, style: .continuous)
                    .fill(Theme.Palette.hover.color)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.well, style: .continuous)
                        .strokeBorder(Theme.Palette.hairline.color.opacity(0.6), lineWidth: 0.5))
            }
    }
}
