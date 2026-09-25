import SwiftUI

// The main window's seam (docs/RUN-UI-1.md K9). The types are plan-owned; change them only
// through the overseer.

enum ModuleID: String, CaseIterable, Codable { case library, studio, edit, settings }

enum ModuleSection: Int, Comparable {
    case capture, create, app

    static func < (lhs: ModuleSection, rhs: ModuleSection) -> Bool { lhs.rawValue < rhs.rawValue }
}

@MainActor protocol CamcordModule {
    var id: ModuleID { get }
    var title: LocalizedStringResource { get }
    var symbol: String { get }            // SF Symbol name
    var section: ModuleSection { get }
    var isAvailable: Bool { get }         // false → shown as "Soon", not selectable
    func makeView() -> AnyView
}

enum DockIconMode: String, Codable, CaseIterable { case whileWindowOpen, always, never }  // default .whileWindowOpen

// MARK: - Registry

/// Every module the main window shows, in sidebar order. Adding one is a new type conforming
/// to `CamcordModule` plus one line here.
@MainActor
enum ModuleRegistry {
    static let all: [any CamcordModule] = [
        LibraryModule(),
        StudioModule(),
        EditModule(),
        SettingsModule(),
    ]

    static func module(_ id: ModuleID) -> (any CamcordModule)? {
        all.first { $0.id == id }
    }

    /// The modules of one sidebar section, in registry order.
    static func modules(in section: ModuleSection) -> [any CamcordModule] {
        all.filter { $0.section == section }
    }

    /// The sections that have modules, in order.
    static var sections: [ModuleSection] {
        Array(Set(all.map(\.section))).sorted()
    }

    /// The module to show: `id` when it exists and is available, else the first available.
    static func selectable(_ id: ModuleID?) -> ModuleID {
        if let id, let module = module(id), module.isAvailable { return id }
        return all.first(where: \.isAvailable)?.id ?? .library
    }
}

/// The last selected module, persisted so the window reopens where the owner left it.
enum ModuleSelection {
    static let defaultsKey = "mainWindow.selectedModule"

    @MainActor
    static func load(from defaults: UserDefaults) -> ModuleID {
        ModuleRegistry.selectable(defaults.string(forKey: defaultsKey).flatMap(ModuleID.init(rawValue:)))
    }

    static func save(_ id: ModuleID, to defaults: UserDefaults) {
        defaults.set(id.rawValue, forKey: defaultsKey)
    }
}

extension DockIconMode {
    static let defaultsKey = "dockIconMode"

    static func load(from defaults: UserDefaults) -> DockIconMode {
        defaults.string(forKey: defaultsKey).flatMap(DockIconMode.init(rawValue:)) ?? .whileWindowOpen
    }

    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    var title: LocalizedStringResource {
        switch self {
        case .whileWindowOpen: LocalizedStringResource("While the window is open", comment: "Dock icon setting")
        case .always: LocalizedStringResource("Always", comment: "Dock icon setting")
        case .never: LocalizedStringResource("Never", comment: "Dock icon setting")
        }
    }
}
