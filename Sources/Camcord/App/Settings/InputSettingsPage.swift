import KeyboardShortcuts
import SwiftUI

// MARK: - Mouse & Shortcuts

struct InputSettingsPage: View {
    @Bindable var store: SettingsStore
    private var activity = SettingsActivity()
    @State private var accessibilityTrusted = AccessibilityPermission.isTrusted()
    @State private var conflict: ShortcutConflict?
    /// The last accepted assignment per action, so a rejected duplicate can be put back.
    @State private var accepted: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] = [:]

    init(store: SettingsStore) { self.store = store }

    /// A shortcut just recorded onto an action another one holds. It is reverted at once —
    /// nothing is taken over silently — and the sheet offers the swap.
    struct ShortcutConflict: Identifiable {
        let id = UUID()
        let name: KeyboardShortcuts.Name
        let other: KeyboardShortcuts.Name
        let shortcut: KeyboardShortcuts.Shortcut
        let previous: KeyboardShortcuts.Shortcut?
    }

    /// Every action with a recordable shortcut, in the order the page lists them.
    static let shortcuts: [(name: KeyboardShortcuts.Name, title: LocalizedStringResource)] = [
        (.captureRegion, CaptureKind.region.actionTitle),
        (.captureActiveWindow, CaptureKind.window.actionTitle),
        (.captureFullScreen, CaptureKind.screen.actionTitle),
        (.captureTextRegion, CaptureKind.text.actionTitle),
        (.captureScrolling, CaptureKind.scroll.actionTitle),
        (.toggleRecording, LocalizedStringResource("Start or stop recording", comment: "Shortcut action")),
        (.pauseRecording, LocalizedStringResource("Pause or resume recording", comment: "Shortcut action")),
        (.toggleCameraPreview, LocalizedStringResource("Show or hide the camera preview", comment: "Shortcut action")),
        (.toggleCameraRecording, LocalizedStringResource("Add or remove the camera in the recording", comment: "Shortcut action")),
    ]

    static func title(for name: KeyboardShortcuts.Name) -> LocalizedStringResource {
        shortcuts.first { $0.name == name }?.title ?? LocalizedStringResource(stringLiteral: name.rawValue)
    }

    var body: some View {
        FormPage(title: SettingsGroup.input.title) {
            FormCard(title: LocalizedStringResource("Mouse", comment: "Settings card"),
                     footnote: LocalizedStringResource("Capture modifier: hold the button and drag with the left button for a screenshot, with the right button for text; a tap opens the region picker. Hold → region: hold and drag, release to capture; tap once, then hold, to capture text.",
                                                       comment: "Setting footnote")) {
                mouseRow(LocalizedStringResource("Middle click (wheel)", comment: "Mouse binding"), \.mouseButton3,
                         includeHold: false, key: "tapBindings.mouseButton3", isFirst: true)
                mouseRow(LocalizedStringResource("Mouse button 4", comment: "Mouse binding"), \.mouseButton4,
                         includeHold: true, key: "tapBindings.mouseButton4")
                mouseRow(LocalizedStringResource("Mouse button 5", comment: "Mouse binding"), \.mouseButton5,
                         includeHold: true, key: "tapBindings.mouseButton5")
                mouseRow(LocalizedStringResource("Double-tap right ⌘", comment: "Mouse binding"), \.doubleTapRightCommand,
                         includeHold: false, key: "tapBindings.doubleTapRightCommand")
                if store.tapBindings.anyEnabled, !accessibilityTrusted {
                    FormRow(label: LocalizedStringResource("Accessibility is needed for these", comment: "Setting status")) {
                        Button { AccessibilityPermission.requestAccess() } label: {
                            Text("Open System Settings", comment: "Button: open the privacy pane")
                        }
                    }
                }
            }
            FormCard(title: LocalizedStringResource("Keyboard shortcuts", comment: "Settings card"),
                     footnote: LocalizedStringResource("Click a field and press the keys you want.", comment: "Setting footnote")) {
                ForEach(Array(Self.shortcuts.enumerated()), id: \.element.name) { index, entry in
                    FormRow(label: entry.title, isFirst: index == 0) {
                        KeyboardShortcuts.Recorder(for: entry.name) { shortcutChanged(entry.name, to: $0) }
                    }
                    .settingsKey("KeyboardShortcuts_\(entry.name.rawValue)")
                }
            }
        }
        .onChange(of: activity.isActive, initial: true) { _, active in
            guard active else { conflict = nil; return }
            accepted = ShortcutCatalogue.assignments()
            accessibilityTrusted = AccessibilityPermission.isTrusted()
        }
        .sheet(item: $conflict) { ConflictSheet(conflict: $0, dismiss: { conflict = nil }, takeOver: takeOver) }
        .task(id: activity.isActive) {
            guard activity.isActive else { return }
            // Follow grants and revocations while the page is visible. A new grant re-applies
            // the configured bindings; disappearing cancels the poll.
            await SettingsActivity.poll {
                guard activity.isActive else { return }
                let trusted = AccessibilityPermission.isTrusted()
                if trusted, !accessibilityTrusted { store.reapplyTapBindings() }
                accessibilityTrusted = trusted
            }
        }
    }

    private func mouseRow(_ label: LocalizedStringResource, _ keyPath: WritableKeyPath<TapBindings, TapAction?>,
                          includeHold: Bool, key: String, isFirst: Bool = false) -> some View {
        FormRow(label: label, isFirst: isFirst) {
            Picker(selection: Binding(get: { store.tapBindings[keyPath: keyPath] },
                                      set: { store.tapBindings[keyPath: keyPath] = $0 })) {
                Text("Off", comment: "Accessibility value: a meter that is not measuring").tag(TapAction?.none)
                Text(CaptureKind.region.actionTitle).tag(TapAction?.some(.captureRegion))
                if includeHold {
                    Text("Capture modifier (+ left / right)", comment: "Mouse binding option").tag(TapAction?.some(.captureModifier))
                    Text("Hold → region", comment: "Mouse binding option").tag(TapAction?.some(.holdCaptureRegion))
                }
                Text("Paste", comment: "Mouse binding option").tag(TapAction?.some(.paste))
                Text("Start or stop recording", comment: "Shortcut action").tag(TapAction?.some(.toggleRecording))
            } label: { Text(label) }
            .labelsHidden().fixedSize()
        }
        .settingsKey(key)
    }

    /// A duplicate is never taken silently: it is put back the moment it is seen, and the sheet
    /// asks whether the user meant to move it off the other action.
    private func shortcutChanged(_ name: KeyboardShortcuts.Name, to shortcut: KeyboardShortcuts.Shortcut?) {
        guard activity.isActive else { return }
        guard let shortcut else {
            accepted[name] = nil
            return
        }
        guard let other = ShortcutCatalogue.conflict(assigning: shortcut, to: name, in: ShortcutCatalogue.assignments()) else {
            accepted[name] = shortcut
            return
        }
        let previous = accepted[name]
        KeyboardShortcuts.setShortcut(previous, for: name)
        conflict = ShortcutConflict(name: name, other: other, shortcut: shortcut, previous: previous)
    }

    private func takeOver(_ conflict: ShortcutConflict) {
        guard activity.isActive else { return }
        KeyboardShortcuts.setShortcut(nil, for: conflict.other)
        KeyboardShortcuts.setShortcut(conflict.shortcut, for: conflict.name)
        accepted[conflict.other] = nil
        accepted[conflict.name] = conflict.shortcut
        self.conflict = nil
    }
}

private struct ConflictSheet: View {
    let conflict: InputSettingsPage.ShortcutConflict
    let dismiss: () -> Void
    let takeOver: (InputSettingsPage.ShortcutConflict) -> Void

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "command")
                .font(Theme.Font.title)
                .foregroundStyle(Theme.Palette.ink.color)
                .frame(width: 48, height: 48)
                .background(Theme.Palette.selection.color, in: Circle())
            Text("This shortcut is taken", comment: "Shortcut conflict title")
                .font(Theme.Font.rowStrong)
            KeyCap(shortcut: conflict.shortcut)
            Text("It belongs to “\(String(localized: InputSettingsPage.title(for: conflict.other)))”. If you take it over, that action has no shortcut.",
                 comment: "Shortcut conflict body")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.ink2.color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.s) {
                Button(action: dismiss) { Text("Cancel", comment: "Button") }
                    .keyboardShortcut(.cancelAction)
                Button { takeOver(conflict) } label: { Text("Take it over", comment: "Button: move a shortcut to this action") }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Palette.ink.color)
            }
            .controlSize(.large)
            .padding(.top, Theme.Space.s)
        }
        .padding(Theme.Space.xl)
        .frame(width: 340)
    }
}
