import Observation
import SwiftUI

// The main window's controls answer the pointer the way the menu-bar panel's do: the hovered
// symbol rises, grows and glows in ink, its siblings step back, a press gives a little. The
// look of each state is a pure function of `KitState`, so every state can be rendered and
// tested without a pointer; the views only decide which state they are in.

/// What a window control shows.
struct KitState: Equatable, Sendable {
    /// nil: nothing in the control's group is hovered; true: this control; false: a sibling.
    var focus: Bool?
    var pressed = false
    var selected = false
    var enabled = true

    init(focus: Bool? = nil, pressed: Bool = false, selected: Bool = false, enabled: Bool = true) {
        self.focus = focus
        self.pressed = pressed
        self.selected = selected
        self.enabled = enabled
    }

    /// Only an enabled control rises.
    var lifted: Bool { focus == true && enabled }
}

/// The hover response resolved for one control: how much its symbol grows and rises, how
/// strongly it glows, and how far the whole control steps back.
struct KitLift: Equatable, Sendable {
    enum Kind: Sendable {
        /// An icon or a chip's symbol.
        case symbol
        /// The larger symbol over a name.
        case tool
        /// A row that carries words: its siblings step back less, to stay legible.
        case row
    }

    var scale: CGFloat
    var rise: CGFloat
    var glow: Double
    var opacity: Double

    static func resolve(_ state: KitState, kind: Kind, reduceMotion: Bool) -> KitLift {
        typealias L = Theme.Window.Lift
        let moves = state.lifted && !reduceMotion
        let opacity: Double = if !state.enabled {
            L.disabled
        } else if state.focus == false {
            kind == .row ? L.rowSibling : L.sibling
        } else {
            1
        }
        return KitLift(scale: moves ? (kind == .tool ? L.toolScale : L.symbolScale) : 1,
                       rise: moves ? -(kind == .tool ? L.toolRise : L.symbolRise) : 0,
                       glow: state.lifted ? L.glowOpacity : 0,
                       opacity: opacity)
    }

    /// How much a pressed control gives: a symbol the panel's 8 %, a wide surface 2 %.
    static func pressScale(pressed: Bool, wide: Bool, reduceMotion: Bool) -> CGFloat {
        guard pressed, !reduceMotion else { return 1 }
        return wide ? Theme.Window.Lift.widePress : Theme.Window.Lift.press
    }
}

/// One hover focus shared by a row of controls, like each of the panel's cells: the control
/// under the pointer is `true`, the others `false`.
@MainActor @Observable
final class KitHoverGroup {
    private(set) var current: AnyHashable?

    func focus(of id: AnyHashable) -> Bool? { current.map { $0 == id } }

    /// Leaving a control clears the focus only if no sibling has taken it in the meantime.
    func hover(_ id: AnyHashable, inside: Bool) {
        if inside { current = id } else if current == id { current = nil }
    }
}

extension EnvironmentValues {
    @Entry var kitHoverGroup: KitHoverGroup?
}

private struct KitHoverGroupModifier: ViewModifier {
    @State private var group = KitHoverGroup()
    func body(content: Content) -> some View { content.environment(\.kitHoverGroup, group) }
}

extension View {
    /// The controls inside share one hover focus: hovering one steps the others back.
    func kitHoverGroup() -> some View { modifier(KitHoverGroupModifier()) }
}

/// A control's hover focus: from its group when it has one, else from its own pointer.
@MainActor
struct KitHover: DynamicProperty {
    @Environment(\.kitHoverGroup) private var group
    @State private var own = false
    @State private var id = UUID()

    var focus: Bool? { group.map { $0.focus(of: id) } ?? (own ? true : nil) }

    func update(inside: Bool) {
        if let group { group.hover(id, inside: inside) } else { own = inside }
    }
}

// MARK: - Shared effects

extension View {
    /// The panel's lit symbol: grown, raised and glowing in ink.
    func kitLift(_ lift: KitLift, glowRadius: CGFloat = Theme.Window.Lift.glowRadius) -> some View {
        scaleEffect(lift.scale)
            .offset(y: lift.rise)
            .shadow(color: Theme.Palette.ink.color.opacity(lift.glow), radius: glowRadius)
    }

    /// A press drawn from a state (the gallery and tests) rather than from a live button.
    func kitPressed(_ pressed: Bool, wide: Bool = false) -> some View {
        modifier(KitPressEffect(pressed: pressed, wide: wide))
    }
}

private struct KitPressEffect: ViewModifier {
    let pressed: Bool
    let wide: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .scaleEffect(KitLift.pressScale(pressed: pressed, wide: wide, reduceMotion: reduceMotion))
            .animation(reduceMotion ? nil : Theme.Window.Motion.press, value: pressed)
    }
}

/// Every window control gives a little under the pointer, like the panel's.
struct KitPressStyle: ButtonStyle {
    var wide = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.kitPressed(configuration.isPressed, wide: wide)
    }
}
