import AppKit
import SwiftUI

/// A native menu containing the existing Picker, with an opaque readable selected label.
struct SettingsPopup<Options: View>: View {
    let label: LocalizedStringResource
    let value: String
    @ViewBuilder var options: Options
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Menu { options } label: {
            HStack(spacing: Theme.Settings.popupGap) {
                Text(verbatim: value).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.ink3.color)
            }
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Palette.ink.color)
            .padding(.leading, Theme.Settings.popupLeading)
            .padding(.trailing, Theme.Settings.popupTrailing)
            .frame(height: Theme.Settings.popupHeight)
            .background(Theme.Palette.raised.color, in: .rect(cornerRadius: Theme.Settings.popupRadius))
            .opacity(isEnabled ? 1 : Theme.Settings.disabledOpacity)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: Theme.Settings.popupMaximumWidth, alignment: .trailing)
        .help(Text(verbatim: value))
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(verbatim: value))
    }
}

/// The shared native slider remains unchanged; this owned host forwards Settings AX text.
struct SettingsNativeValueSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: LocalizedStringResource
    let format: (Double) -> String
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.locale) private var locale

    func makeNSView(context: Context) -> SettingsSliderHost {
        SettingsSliderHost(content: content, label: label, locale: locale, valueDescription: format(value))
    }

    func updateNSView(_ view: SettingsSliderHost, context: Context) {
        view.host.rootView = content
        view.updateLabel(label, locale: locale)
        view.valueDescription = format(value)
        view.needsLayout = true
    }

    private var content: SettingsSliderContent {
        SettingsSliderContent(value: $value, range: range, enabled: isEnabled)
    }
}

struct SettingsSliderContent: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let enabled: Bool
    var body: some View { CamcordSlider(value: $value, range: range).disabled(!enabled) }
}

final class SettingsSliderHost: NSView {
    let host: NSHostingView<SettingsSliderContent>
    private(set) var label: String
    var valueDescription: String
    private var localizedLabelResource: LocalizedStringResource
    private let localize: (LocalizedStringResource) -> String

    init(content: SettingsSliderContent, label: LocalizedStringResource, locale: Locale,
         valueDescription: String, localize: @escaping (LocalizedStringResource) -> String = { String(localized: $0) }) {
        var resource = label
        resource.locale = locale
        host = NSHostingView(rootView: content)
        localizedLabelResource = resource
        self.localize = localize
        self.label = localize(resource)
        self.valueDescription = valueDescription
        super.init(frame: .zero)
        addSubview(host)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    func updateLabel(_ label: LocalizedStringResource, locale: Locale) {
        var resource = label
        resource.locale = locale
        // The full resource includes its key, values, table and bundle; the effective locale
        // keeps an environment language change from reusing the previous accessibility text.
        guard resource != localizedLabelResource else { return }
        localizedLabelResource = resource
        self.label = localize(resource)
    }

    override func layout() {
        super.layout()
        host.frame = bounds
        host.layoutSubtreeIfNeeded()
        applyAccessibility(in: host)
    }

    private func applyAccessibility(in view: NSView) {
        if let slider = view as? NSSlider {
            slider.setAccessibilityLabel(label)
            slider.setAccessibilityValueDescription(valueDescription)
        } else {
            for child in view.subviews { applyAccessibility(in: child) }
        }
    }
}
