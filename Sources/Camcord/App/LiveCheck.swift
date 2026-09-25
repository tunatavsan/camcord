import AppKit

/// Focus-safe hooks for RUN UI-2's live checks (docs/design/native/SPEC.md §7). Off unless the
/// app's `liveCheck` default is true; then a distributed notification can put a surface on
/// screen WITHOUT activating the app and set the app's own appearance, so dark and light
/// screenshots never take the owner's focus or touch their system setting.
///
///     defaults write dev.tavsan.camcord liveCheck -bool true
///     post "dev.tavsan.camcord.livecheck" with object "window library" | "appearance dark" | …
@MainActor
final class LiveCheck {
    static let notificationName = Notification.Name("dev.tavsan.camcord.livecheck")
    static let defaultsKey = "liveCheck"

    enum Command: Equatable {
        /// Show the main window on a module, without activating.
        case window(ModuleID)
        /// The app's appearance: dark, light, or nil for the system's.
        case appearance(NSAppearance.Name?)
        /// The app's own Increase Contrast: high, normal, or nil for the system's.
        case contrast(Bool?)
        /// Show the Design Lab on a page, without activating.
        case lab(DesignLabPage)
        /// Show the first-run window, as if Screen Recording were not yet allowed (`ask`), allowed
        /// (`granted`), or as it really is (nil).
        case firstRun(simulatedGrant: Bool?)
        /// Close what the live check opened.
        case close

        static func parse(_ text: String) -> Command? {
            let words = text.split(separator: " ").map(String.init)
            guard let verb = words.first else { return nil }
            let argument = words.dropFirst().first
            switch verb {
            case "window":
                return ModuleID(rawValue: argument ?? "library").map(Command.window)
            case "appearance":
                switch argument {
                case "dark": return .appearance(.darkAqua)
                case "light": return .appearance(.aqua)
                case "system": return .appearance(nil)
                default: return nil
                }
            case "contrast":
                switch argument {
                case "high": return .contrast(true)
                case "normal": return .contrast(false)
                case "system": return .contrast(nil)
                default: return nil
                }
            case "lab":
                return DesignLabPage(rawValue: argument ?? "tokens").map(Command.lab)
            case "firstrun":
                switch argument {
                case "ask": return .firstRun(simulatedGrant: false)
                case "granted": return .firstRun(simulatedGrant: true)
                case nil: return .firstRun(simulatedGrant: nil)
                default: return nil
                }
            case "close":
                return .close
            default:
                return nil
            }
        }
    }

    private var observer: NSObjectProtocol?

    /// Nil (no listener at all) unless the default is on.
    init?(defaults: UserDefaults, center: DistributedNotificationCenter = .default(),
          handle: @escaping @MainActor (Command) -> Void) {
        guard defaults.bool(forKey: Self.defaultsKey) else { return nil }
        observer = center.addObserver(forName: Self.notificationName, object: nil, queue: .main) { note in
            let text = note.object as? String
            MainActor.assumeIsolated {
                guard let text, let command = Command.parse(text) else {
                    DiagnosticsLog.append("livecheck ignored=\(text ?? "nil")")
                    return
                }
                DiagnosticsLog.append("livecheck \(text)")
                handle(command)
            }
        }
    }

    isolated deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }
}
