import AppKit
import SwiftUI

@MainActor
final class PinnedScreenshotController: NSObject, NSWindowDelegate {
    private struct Pin { let panel: NSPanel; let pixels: Int }
    var claimClipboardPublication: (@MainActor () -> (@MainActor () -> Bool))?
    private var localClipboardRequests = LatestRequestGate()
    private var copying = false
    private var pins: [UUID: Pin] = [:]
    var count: Int { pins.count }
    var pixelCount: Int { pins.values.reduce(0) { $0 + $1.pixels } }
    static func canPin(width: Int, height: Int, count: Int, pixelCount: Int) -> Bool {
        width > 0 && height > 0 && count >= 0 && count < 5 && pixelCount >= 0 && pixelCount <= 100_000_000 && height <= 100_000_000 / width && width * height <= 100_000_000 - pixelCount
    }
    func pin(_ rendered: EditorRendered) throws {
        let image = rendered.image
        guard Self.canPin(width: image.width, height: image.height, count: count, pixelCount: pixelCount) else { throw EditorError.limit }
        let id = UUID()
        let ratio = CGFloat(image.height) / CGFloat(image.width)
        let width: CGFloat = min(560, max(200, rendered.pointSize.width))
        let panel = NSPanel(contentRect: CGRect(x: 120, y: 120, width: width, height: width * ratio + 44), styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = String(localized: "Pinned screenshot"); panel.level = .floating; panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false; panel.delegate = self; panel.contentAspectRatio = CGSize(width: image.width, height: image.height)
        panel.minSize = CGSize(width: 160, height: 160 * ratio + 44)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: PinnedScreenshotView(rendered: rendered, copy: { [weak self] in await self?.copy(rendered) }, close: { [weak panel] in panel?.close() }))
        pins[id] = Pin(panel: panel, pixels: image.width * image.height)
        panel.orderFrontRegardless()
    }
    func copy(_ rendered: EditorRendered, to pasteboard: NSPasteboard = .general) async -> String? {
        guard !copying else { return nil }
        copying = true; defer { copying = false }
        let token = localClipboardRequests.begin()
        let canPublish = claimClipboardPublication?() ?? { [weak self] in self?.localClipboardRequests.isCurrent(token) == true }
        let copied = await EditorClipboardPublisher.copyPNG(rendered.image, pointSize: rendered.pointSize, to: pasteboard, shouldPublish: { !Task.isCancelled && canPublish() })
        return !copied && !Task.isCancelled && canPublish() ? String(localized: "The edited image could not be copied.") : nil
    }
    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel, let id = pins.first(where: { $0.value.panel === panel })?.key else { return }
        pins[id] = nil
    }
    func closeAll() { for pin in Array(pins.values) { pin.panel.close() }; pins.removeAll() }
}

private struct PinnedScreenshotView: View {
    let rendered: EditorRendered
    let copy: @MainActor () async -> String?
    let close: () -> Void
    @State private var exportURL: URL?
    @State private var error: String?
    @State private var cache = EditorTemporaryExports()
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Button { Task { error = await copy() } } label: { Label("Copy", systemImage: "doc.on.doc") }
                if let exportURL { ShareLink(item: exportURL) { Label("Share", systemImage: "square.and.arrow.up") } }
                Spacer()
                Button(action: close) { Label("Close", systemImage: "xmark") }
            }
            .labelStyle(.iconOnly).buttonStyle(.borderless).font(Theme.Font.body).foregroundStyle(Theme.Palette.ink.color)
            .padding(Theme.Space.s).camcordGlass(.chrome, in: Rectangle())
            if let exportURL {
                Image(nsImage: NSImage(cgImage: rendered.image, size: rendered.pointSize)).resizable().scaledToFit().draggable(exportURL)
                    .accessibilityLabel("Pinned screenshot")
            } else { Image(nsImage: NSImage(cgImage: rendered.image, size: rendered.pointSize)).resizable().scaledToFit().accessibilityLabel("Pinned screenshot") }
            if let error { Text(error).font(Theme.Font.caption).foregroundStyle(Theme.Palette.ink2.color) }
        }
        .background(Theme.Palette.surface.color)
        .task { do { let owned = cache; exportURL = try await Task.detached { try owned.write(rendered.png) }.value } catch { self.error = error.localizedDescription } }
        .onDisappear { cache.cleanup() }
    }
}
