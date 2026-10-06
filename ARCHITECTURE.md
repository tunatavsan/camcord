# Architecture

Camcord is one executable target, `Camcord`, built with Swift 6 strict concurrency, plus the vendored
`KeyboardShortcuts` package. The app is an agent (`LSUIElement`): it lives in the menu bar and, by default, shows a Dock
icon only while its main window is open.

## Layout

| Folder | Contents |
| --- | --- |
| `Capture` | `ScreenshotService` (ScreenCaptureKit calls per capture kind), `CaptureCoordinator` (the screenshot and text flows), the scrolling capture session and stitcher, Vision text and barcode recognition, clipboard writing. |
| `Recording` | `RecordingController` (main-actor flow), `RecordingEngine` (one `SCStream` per recording), `StreamWriter` (the `AVAssetWriter` hot path), audio processing and mixing, the camera source and compositor. |
| `Overlay` | Panels drawn over other apps: the selection overlay, the window picker, the screenshot card, pins, the recording hub, the countdown and the recording frame. |
| `Hotkeys` | `HotkeyCenter` for keyboard shortcuts and `EventTapEngine` for mouse buttons and double taps. |
| `App` | App lifecycle, the status item and menu-bar panel, the main window and its modules (Library, Studio, Editor, Settings), the design system and diagnostics. |

## Taking a screenshot

1. A shortcut, the panel or the main window asks `CaptureCoordinator` for a capture kind.
2. For a region, `ScreenshotService.captureFrozenDesktop` first samples the display's pixels and the window list. The
   selection overlay is drawn over that frozen image, so menus and tooltips that close when the overlay appears are
   still in the shot, and the result is cut from the same pixels the user selected.
3. A window is captured as it looks on screen (`WindowAppearance`): the display's pixels inside the window's own
   shape, so translucent windows keep what shows through them.
4. The image becomes a `ScreenshotDelivery` with a stable identity. `ClipboardWriter` encodes PNG off the main actor
   and writes the pasteboard; saving to disk, if enabled, runs alongside. `ScreenshotDeliveryFanout` routes every
   event to the Library and to the card that shows that capture.
5. The screenshot card offers drag, save, pin and edit. Pins and cards are separate windows that keep their own
   presentation state.

## Scrolling capture

`ScrollingCaptureSession` owns one capture at a time. Frames are taken after the page settles, and `ScrollStitcher`
measures the real shift between frames by row correlation rather than trusting scroll deltas. It detects sticky
header and footer bands so they appear once. In automatic mode `AutoScrollDriver` moves the page one step at a time and
waits for the measured shift before the next step, so the scroll events themselves do not have to be exact.

## Recording

1. `RecordingController` picks the target with the same selection overlay and handles permissions and the countdown.
2. `RecordingEngine` builds the `SCContentFilter` and `SCStreamConfiguration` and starts one `SCStream` with screen,
   system audio and microphone outputs. A translucent window is recorded from its display with only itself and the
   windows below it (`SeenWindow`).
3. `StreamWriter` receives every sample buffer on a single confined queue and appends it to an `AVAssetWriter`.
   `PauseClock` gives video, system audio and microphone one shared timeline, so pause and resume do not leave gaps.
4. When the camera is on, `CameraCompositor` draws the camera tile into each frame in one Core Image pass.
5. When a recording has more than one audio track, `AudioTrackMixer` mixes them into the first track after the file is
   finalized, without re-encoding video. If anything fails after recording starts, the partial file is kept and the
   user is told.

## Hotkeys

Keyboard shortcuts use `KeyboardShortcuts` (Carbon hot keys, no permission needed). Mouse side buttons and double taps
use a `CGEventTap`, which needs Accessibility permission and is created only when such a binding is enabled. No
shortcut is assigned by default.

## Interface

SwiftUI views live in AppKit windows and panels. Colors, type, spacing, radii and motion come from
`App/Design/Theme.swift`; `DesignTokenLiteralTests` fails when a file that should use tokens contains a literal color, font size or
duration. User-facing
text lives in `Resources/Localizable.xcstrings`, and `LocalizationCatalogTests` checks every key the compiler emits
against it.

## Diagnostics

`DiagnosticsLog` appends short lines about capture triggers, scrolling sessions and recordings to
`~/Library/Logs/Camcord/diagnostics.log`, which is restarted when it grows too large. Nothing is sent anywhere.

## Tests

`Tests/CamcordTests` uses Swift Testing. Tests inject clocks, devices and `UserDefaults` suites and use named
pasteboards, so they run unattended without Screen Recording permission. Tests that need real windows, devices or
captures run only when their environment variable is set.
