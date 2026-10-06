import SwiftUI

/// The Settings module's groups, in sidebar order.
enum SettingsGroup: String, CaseIterable, Identifiable, Codable {
    case general, screenshot, recording, camera, input, library, permissions

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .general: LocalizedStringResource("General", comment: "Settings group")
        case .screenshot: LocalizedStringResource("Screenshot", comment: "Settings group")
        case .recording: LocalizedStringResource("Recording", comment: "Settings group")
        case .camera: LocalizedStringResource("Camera", comment: "Chip: the camera tile on or off")
        case .input: LocalizedStringResource("Mouse & Shortcuts", comment: "Settings group")
        case .library: LocalizedStringResource("Library", comment: "Main window module")
        case .permissions: LocalizedStringResource("Permissions", comment: "Settings group")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .screenshot: "viewfinder"
        case .recording: "record.circle"
        case .camera: "video"
        case .input: "keyboard"
        case .library: "rectangle.stack"
        case .permissions: "lock.shield"
        }
    }

    static let defaultsKey = "settings.group"

    static func load(from defaults: UserDefaults) -> SettingsGroup {
        defaults.string(forKey: defaultsKey).flatMap(SettingsGroup.init(rawValue:)) ?? .general
    }
}
