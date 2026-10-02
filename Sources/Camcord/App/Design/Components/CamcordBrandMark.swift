import AppKit
import SwiftUI

/// The same lens artwork is shared by the menu bar and in-app brand headers.
@MainActor
enum CamcordBrandAssets {
    static let templateSize = NSSize(width: 18, height: 18)

    /// Keep the vector representation and one image identity through idle restoration.
    static let templateImage: NSImage = {
        var url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "svg")
        #if DEBUG
        // SwiftPM tests and previews run outside the packaged app bundle.
        if url == nil {
            url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/MenuBarIcon.svg")
        }
        #endif
        guard let url, let image = loadTemplateImage(at: url) else {
            preconditionFailure("The Camcord menu bar artwork is missing or unreadable.")
        }
        return image
    }()

    static func loadTemplateImage(at url: URL) -> NSImage? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        image.size = templateSize
        image.isTemplate = true
        return image
    }
}

struct CamcordBrandMark: View {
    var body: some View {
        Image(nsImage: CamcordBrandAssets.templateImage)
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .accessibilityHidden(true)
    }
}
