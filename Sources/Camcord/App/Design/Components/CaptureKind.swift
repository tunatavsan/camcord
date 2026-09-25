import KeyboardShortcuts
import SwiftUI

/// The five captures, each with one name everywhere (K8): the window toolbar, the panel's keys,
/// the empty Library's key caps, the menu. SF Symbols only (SPEC N5).
enum CaptureKind: String, CaseIterable, Identifiable, Sendable {
    case region, window, screen, scroll, text

    var id: String { rawValue }

    /// The feature's name: "Region", "Scroll capture".
    var title: LocalizedStringResource {
        switch self {
        case .region: LocalizedStringResource("Region", comment: "Capture kind: a region of the screen")
        case .window: LocalizedStringResource("Window", comment: "Capture kind: one window")
        case .screen: LocalizedStringResource("Screen", comment: "Capture kind: the whole screen")
        case .scroll: LocalizedStringResource("Scroll capture", comment: "Capture kind: a long, scrolled capture")
        case .text: LocalizedStringResource("Text", comment: "Capture kind: recognise the text in a region")
        }
    }

    /// The label under a small key where the full name does not fit (the panel's well).
    var shortTitle: LocalizedStringResource {
        switch self {
        case .scroll: LocalizedStringResource("Scroll", comment: "Short label of the Scroll capture key in the menu-bar panel")
        default: title
        }
    }

    /// What the control does, for buttons, menus and VoiceOver.
    var actionTitle: LocalizedStringResource {
        switch self {
        case .region: LocalizedStringResource("Capture a region", comment: "Action: capture a region")
        case .window: LocalizedStringResource("Capture a window", comment: "Action: capture a window")
        case .screen: LocalizedStringResource("Capture the screen", comment: "Action: capture the whole screen")
        case .scroll: LocalizedStringResource("Start a scroll capture", comment: "Action: start a scroll capture")
        case .text: LocalizedStringResource("Capture text", comment: "Action: recognise the text in a region")
        }
    }

    var symbol: String {
        switch self {
        case .region: "rectangle.dashed"
        case .window: "macwindow"
        case .screen: "display"
        case .scroll: "arrow.down.document"
        case .text: "text.viewfinder"
        }
    }

    var shortcutName: KeyboardShortcuts.Name {
        switch self {
        case .region: .captureRegion
        case .window: .captureActiveWindow
        case .screen: .captureFullScreen
        case .scroll: .captureScrolling
        case .text: .captureTextRegion
        }
    }

    /// The hotkey as the owner set it ("⇧⌘2"), or nil when none is assigned.
    @MainActor var shortcut: KeyboardShortcuts.Shortcut? { KeyboardShortcuts.getShortcut(for: shortcutName) }

    /// Starts this capture through the coordinator's existing entry points.
    @MainActor func perform(with coordinator: CaptureCoordinator) async {
        switch self {
        case .region: await coordinator.captureRegionInteractive()
        case .window: await coordinator.captureActiveWindow()
        case .screen: await coordinator.captureFullScreen()
        case .scroll: await coordinator.captureScrollingInteractive()
        case .text: await coordinator.captureTextRegionInteractive()
        }
    }
}
