import AppKit
import SwiftUI

/// Owns the menu-bar popover (left-click surface). Transient behavior: it closes
/// itself on any outside click; actions that open other UI (overlay, settings)
/// close it explicitly first so the surfaces never fight.
@MainActor
final class PanelController {
    private let popover = NSPopover()

    init(model: RecordingStateModel, actions: PanelActions) {
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: CapturePanelView(model: model, actions: actions)
        )
    }

    var isShown: Bool { popover.isShown }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            close()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func close() {
        popover.performClose(nil)
    }
}
