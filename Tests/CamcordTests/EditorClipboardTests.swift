import AppKit
import CoreGraphics
import ImageIO
import Testing
@testable import Camcord

private actor EditorClipboardGate {
    private var started = false
    private var observer: CheckedContinuation<Void, Never>?
    private var work: CheckedContinuation<Void, Never>?
    func suspend() async { started = true; observer?.resume(); observer = nil; await withCheckedContinuation { work = $0 } }
    func waitForStart() async { if started { return }; await withCheckedContinuation { observer = $0 } }
    func resume() { work?.resume(); work = nil }
}

@Suite("Editor and capture clipboard ownership") @MainActor
struct EditorClipboardTests {
    private func board() -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name("editor-epoch-\(UUID().uuidString)")) }
    private func operations(board: NSPasteboard) -> CaptureCoordinator.Operations {
        var result = CaptureCoordinator.Operations(); result.feedback = false; result.screenCaptureAuthorized = { true }; result.screenshotSettings = { ScreenshotSettings(saveToDisk: false) }
        result.copyPNG = { image, size, _, publish, _ in await ClipboardWriter.copyPNG(image, pointSize: size, to: board, shouldPublish: publish) }
        return result
    }
    private func session(coordinator: CaptureCoordinator, clipboard: EditorSession.ClipboardOperations = EditorSession.ClipboardOperations()) throws -> EditorSession {
        let result = EditorSession(clipboard: clipboard)
        result.claimClipboardPublication = { coordinator.claimClipboardPublication() }
        result.open(CapturedScreenshot(id: UUID(), image: try EditorRendererTests.image(), pointSize: CGSize(width: 8, height: 6), kind: .screenshot, saveToDiskRequested: false))
        result.add(tool: .redact, from: .zero, to: CGPoint(x: 6, y: 6)); return result
    }
    private func pixel(_ board: NSPasteboard) throws -> String {
        let data = try #require(board.data(forType: .png)), source = try #require(CGImageSourceCreateWithData(data as CFData, nil)), image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try EditorRenderer.sample(image, at: CGPoint(x: 2, y: 2))
    }
    @Test("Default editor and pin copies publish flattened DPI-only PNG to named pasteboards")
    func defaultCopyMetadata() async throws {
        let session = EditorSession()
        session.open(CapturedScreenshot(id: UUID(), image: try EditorRendererTests.image(), pointSize: CGSize(width: 8, height: 6), kind: .screenshot, saveToDiskRequested: false))
        session.add(tool: .redact, from: .zero, to: CGPoint(x: 6, y: 6))
        let editorBoard = board(), pinBoard = board()
        #expect(await session.copy(to: editorBoard))
        let rendered = try await session.flattened(), pins = PinnedScreenshotController()
        #expect(await pins.copy(rendered, to: pinBoard) == nil)
        for board in [editorBoard, pinBoard] {
            #expect(try pixel(board) == "#000000")
            let data = try #require(board.data(forType: .png))
            #expect(data == (try rendered.png))
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            #expect(properties[kCGImagePropertyExifDictionary] == nil)
            #expect(abs((properties[kCGImagePropertyDPIWidth] as? Double ?? 0) - 144) < 0.1)
        }
        session.stop()
    }
    @Test("A newer capture supersedes an editor copy before delayed encoding publishes")
    func newCaptureBeatsEditor() async throws {
        let board = board(), gate = EditorClipboardGate(), coordinator = CaptureCoordinator(operations: operations(board: board))
        var clipboard = EditorSession.ClipboardOperations()
        clipboard.copyPNG = { image, size, board, publish in await gate.suspend(); return await ClipboardWriter.copyPNG(image, pointSize: size, to: board, shouldPublish: publish) }
        let session = try session(coordinator: coordinator, clipboard: clipboard)
        let oldCopy = Task { await session.copy(to: board) }; await gate.waitForStart()
        #expect(await coordinator.deliverScreenshotForTesting(try EditorRendererTests.image(secret: 7), pointSize: CGSize(width: 8, height: 6)) == true)
        await gate.resume(); #expect(await oldCopy.value == false); #expect(try pixel(board) == "#072846")
        #expect(session.error == nil); session.stop()
    }
    @Test("A newer editor copy supersedes an older capture before delayed encoding publishes")
    func newEditorBeatsCapture() async throws {
        let board = board(), gate = EditorClipboardGate()
        var operations = operations(board: board)
        operations.copyPNG = { image, size, _, publish, _ in await gate.suspend(); return await ClipboardWriter.copyPNG(image, pointSize: size, to: board, shouldPublish: publish) }
        let coordinator = CaptureCoordinator(operations: operations), image = try EditorRendererTests.image(secret: 7)
        let oldCapture = Task { await coordinator.deliverScreenshotForTesting(image, pointSize: CGSize(width: 8, height: 6)) }; await gate.waitForStart()
        let session = try session(coordinator: coordinator)
        #expect(await session.copy(to: board)); await gate.resume(); #expect(await oldCapture.value == nil)
        #expect(try pixel(board) == "#000000"); session.stop()
    }
    @Test("A cancelled newer capture never resurrects an older editor publication")
    func cancelledNewCaptureKeepsOlderInvalid() async throws {
        let board = board(), encodeGate = EditorClipboardGate(), captureGate = EditorClipboardGate(), image = try EditorRendererTests.image(secret: 7)
        board.clearContents(); board.setString("fixture marker", forType: .string)
        var operations = operations(board: board)
        operations.fullScreen = { await captureGate.suspend(); return (image, CGSize(width: 8, height: 6)) }
        let coordinator = CaptureCoordinator(operations: operations)
        var clipboard = EditorSession.ClipboardOperations()
        clipboard.copyPNG = { image, size, board, publish in await encodeGate.suspend(); return await ClipboardWriter.copyPNG(image, pointSize: size, to: board, shouldPublish: publish) }
        let session = try session(coordinator: coordinator, clipboard: clipboard)
        let oldCopy = Task { await session.copy(to: board) }; await encodeGate.waitForStart()
        let cancelledCapture = Task { await coordinator.captureFullScreen() }; await captureGate.waitForStart()
        cancelledCapture.cancel(); await captureGate.resume(); await cancelledCapture.value
        await encodeGate.resume(); #expect(await oldCopy.value == false)
        #expect(board.string(forType: .string) == "fixture marker"); #expect(board.data(forType: .png) == nil); session.stop()
    }
    @Test("Standalone named-board hex copy claims the same local session gate")
    func hexBeatsPendingImage() async throws {
        let board = board(), gate = EditorClipboardGate()
        var clipboard = EditorSession.ClipboardOperations()
        clipboard.copyPNG = { image, size, board, publish in await gate.suspend(); return await ClipboardWriter.copyPNG(image, pointSize: size, to: board, shouldPublish: publish) }
        let session = EditorSession(clipboard: clipboard)
        session.open(CapturedScreenshot(id: UUID(), image: try EditorRendererTests.image(), pointSize: CGSize(width: 8, height: 6), kind: .screenshot, saveToDiskRequested: false))
        let oldCopy = Task { await session.copy(to: board) }; await gate.waitForStart()
        session.copyHex("#112233", to: board); await gate.resume(); #expect(await oldCopy.value == false)
        #expect(board.string(forType: .string) == "#112233"); #expect(board.data(forType: .png) == nil); session.stop()
    }
}
