import AppKit
import Testing
@testable import Camcord

@Suite("Scrolling capture HUD", .serialized)
@MainActor
struct ScrollPreviewViewTests {
    @Test("Recovery instructions fit without hiding the action", arguments: [
        "Boşluk var · biraz geri kaydır",
        "Tekrarlı içerik · daha kısa kaydır",
        "40.000 px sınırı · İptal edip alanı küçült",
        "Eksik bağlantı · geri kaydırıp yeniden Bitti",
        "Kare hâlâ işleniyor · yeniden Bitti",
        "Son kare alınamadı · yeniden Bitti",
    ])
    func recoveryInstructionsFit(message: String) throws {
        _ = NSApplication.shared
        let view = ScrollPreviewView(frame: CGRect(x: 0, y: 0, width: 208, height: 372))
        view.setBlockingHint(message)
        view.layoutSubtreeIfNeeded()
        let field = try #require(descendants(of: view).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == message })
        let text = NSAttributedString(string: message, attributes: [.font: field.font!])
        let required = text.boundingRect(
            with: CGSize(width: field.bounds.width - 4, height: 1_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        #expect(field.lineBreakMode == .byWordWrapping)
        #expect(field.bounds.height >= ceil(required.height))
        #expect(view.bounds.contains(view.convert(field.bounds, from: field)))
        let siblings = try #require(field.superview).subviews.filter { $0 !== field }
        #expect(!siblings.contains { $0.frame.intersects(field.frame) })
    }

    @Test("Manual HUD exposes only accessible Done and Cancel actions")
    func manualActions() throws {
        _ = NSApplication.shared
        let view = ScrollPreviewView(frame: CGRect(x: 0, y: 0, width: 208, height: 372))
        var actions: [String] = []
        view.onDone = { actions.append("done") }
        view.onCancel = { actions.append("cancel") }

        let buttons = descendants(of: view).filter { $0.accessibilityRole() == .button }
        #expect(buttons.count == 2)
        #expect(Set(buttons.compactMap { $0.accessibilityLabel() }) == ["✓ Bitti", "İptal"])
        #expect(buttons.allSatisfy { view.bounds.contains(view.convert($0.bounds, from: $0)) })

        for title in ["✓ Bitti", "İptal"] {
            let button = try #require(descendants(of: view).first {
                $0.accessibilityRole() == .button && $0.accessibilityLabel() == title
            })
            #expect(button.accessibilityPerformPress())
        }
        #expect(actions == ["done", "cancel"])
    }

    @Test("Preview and status updates leave manual actions clickable")
    func updatesLeaveActionsClickable() throws {
        _ = NSApplication.shared
        let view = ScrollPreviewView(frame: CGRect(x: 0, y: 0, width: 208, height: 372))
        var actions: [String] = []
        view.onDone = { actions.append("done") }
        view.onCancel = { actions.append("cancel") }

        view.update(image: nil, sections: 7)
        view.setBlockingHint("Boşluk var · biraz geri kaydır")
        view.layoutSubtreeIfNeeded()

        let status = try #require(descendants(of: view).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "Boşluk var · biraz geri kaydır" })
        let buttons = descendants(of: view).filter { $0.accessibilityRole() == .button }
        #expect(buttons.allSatisfy { !$0.frame.intersects(status.frame) })
        for button in buttons { #expect(button.accessibilityPerformPress()) }
        #expect(Set(actions) == ["done", "cancel"])

        view.setBlockingHint(nil)
        #expect(descendants(of: view).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue == "7 bölüm · Esc iptal" })
    }

    @Test("Final verification keeps cancellation available and prevents duplicate actions")
    func finalVerificationActions() throws {
        _ = NSApplication.shared
        let view = ScrollPreviewView(frame: CGRect(x: 0, y: 0, width: 208, height: 372))
        var actions: [String] = []
        view.onDone = { actions.append("done") }
        view.onCancel = { actions.append("cancel") }
        view.setFinishing(true)
        #expect(descendants(of: view).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue == "Son kare kontrol ediliyor…" })
        for (title, allowed) in [("Kontrol…", false), ("İptal", true)] {
            let button = try #require(descendants(of: view).first {
                $0.accessibilityRole() == .button && $0.accessibilityLabel() == title
            })
            #expect(button.isAccessibilityEnabled() == allowed)
            #expect(button.accessibilityPerformPress() == allowed)
        }
        #expect(actions == ["cancel"])
        view.setFinishing(false)
        let done = try #require(descendants(of: view).first { $0.accessibilityLabel() == "✓ Bitti" })
        #expect(done.accessibilityPerformPress())
        #expect(actions == ["cancel", "done"])
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
