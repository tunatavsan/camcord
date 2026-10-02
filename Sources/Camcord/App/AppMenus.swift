import AppKit

/// Agent apps still need a native Edit menu while a settings/rename field is key.
/// These nil-target actions follow the responder chain, including field editors.
@MainActor
enum AppMenus {
    static func editingMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Düzenle")
        menu.addItem(withTitle: "Geri Al", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Yinele", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Kes", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Kopyala", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Yapıştır", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Tümünü Seç", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        item.submenu = menu
        return item
    }

    /// ⌘W closes the main window (it never quits the app) and ⌘M minimises it.
    static func windowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: String(localized: "Window", comment: "Menu title"))
        menu.addItem(withTitle: String(localized: "Minimize", comment: "Window menu"),
                     action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: String(localized: "Close", comment: "Window menu"),
                     action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        item.submenu = menu
        return item
    }

    /// ⌘1…⌘4: the main window's modules, in sidebar order (K1). Each item carries its module's
    /// id; `action` on `target` opens the window on it.
    /// The sidebar is always shown (owner, 2026-10-02), so there is no Toggle Sidebar item.
    static func viewMenuItem(target: AnyObject, action: Selector) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: String(localized: "View", comment: "Menu title"))
        for module in ModuleRegistry.all {
            guard let index = ModuleShortcut.index(of: module.id) else { continue }
            let entry = menu.addItem(withTitle: String(localized: module.title), action: action,
                                     keyEquivalent: "\(index)")
            entry.target = target
            entry.representedObject = module.id.rawValue
            entry.image = NSImage(systemSymbolName: module.symbol, accessibilityDescription: nil)
        }
        item.submenu = menu
        return item
    }
}
