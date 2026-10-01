import AppKit
import CryptoKit
import CoreMedia
import SwiftUI
import Testing
@testable import Camcord

/// A normal owned window with actual production controls, held for background CUA
/// and SCK window-ID recording by the external driver. No scripted model tour.
@MainActor @Suite("Editor interaction window", .serialized,
                  .enabled(if: ProcessInfo.processInfo.environment["CAMCORD_EDITOR_INTERACTION"] == "1"))
struct EditorInteractionRenderTests {
    @Test("Responsive owned Editor workspace")
    func windowFixture() async throws {
        let env = ProcessInfo.processInfo.environment
        let sentinel = URL(fileURLWithPath: try #require(env["CAMCORD_EDITOR_GUI_SENTINEL"]))
        let output = URL(fileURLWithPath: try #require(env["CAMCORD_EDITOR_OUTPUT"]), isDirectory: true)
        let repo = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath:sentinel.path), output.path == LibraryFiles.physicalPath(output), output.path != repo.path, !output.path.hasPrefix(repo.path + "/"), (try output.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])).isDirectory == true, try FileManager.default.contentsOfDirectory(atPath:output.path).isEmpty else { throw LibraryFiles.Failure.unsafePath }
        _ = NSApplication.shared; #expect(!NSApp.isActive)
        let finishedLaunchingBefore = NSRunningApplication.current.isFinishedLaunching
        #expect(!NSApp.isActive)
        let image = try neutralImage()
        let markerROI = try checkerROI(image)
        try EditorRendered(image:image, pointSize:CGSize(width:480,height:300)).png.write(to:output.appendingPathComponent("source.png"))
        let fixtureClipboard = EditorFixtureClipboard()
        defer { fixtureClipboard.pasteboard.releaseGlobally() }
        let session = EditorSession(clipboard:fixtureClipboard.operations())
        session.open(CapturedScreenshot(id:UUID(), image:image, pointSize:CGSize(width:480,height:300), kind:.screenshot, saveToDiskRequested:false))
        await session.waitForRendering()
        session.tool = .arrow
        let host = EditorUndoHostingController(rootView: EditorWorkspace(session:session, services:nil).font(Theme.Font.body).foregroundStyle(Theme.Palette.ink.color))
        host.activeEditor = { session }; host.sceneBridgingOptions = [.toolbars,.title]; host.sizingOptions = []
        let screen = try #require(NSScreen.screens.first)
        let size = CGSize(width:1180,height:760)
        let window = NSWindow(contentRect:CGRect(x:screen.visibleFrame.midX-size.width/2,y:screen.visibleFrame.midY-size.height/2,width:size.width,height:size.height),styleMask:[.titled,.closable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.level = .normal; window.hidesOnDeactivate = false
        window.title = "Camcord owned Editor interaction"; window.titlebarAppearsTransparent = true; window.toolbarStyle = .unified
        window.appearance = NSAppearance(named:env["CAMCORD_EDITOR_LOOK"] == "light" ? .aqua : .darkAqua)
        let delegate = EditorInteractionWindowDelegate(session:session); window.delegate = delegate
        window.contentViewController = host; window.setContentSize(size)
        let originalMenu = NSApp.mainMenu
        let menu = NSMenu(); menu.addItem(AppMenus.editingMenuItem()); NSApp.mainMenu = menu
        defer { NSApp.mainMenu = originalMenu; session.stop(); window.orderOut(nil); window.close() }
        window.orderBack(nil); window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        #expect(!window.isKeyWindow && !NSApp.isActive)
        let playback = EditorNativeEventPlayback()
        var playbackTask: Task<Void,Never>?
        defer { playbackTask?.cancel() }
        let finish = output.appendingPathComponent("finish"), deadline = ContinuousClock.now.advanced(by:.seconds(180))
        while ContinuousClock.now < deadline, FileManager.default.fileExists(atPath:sentinel.path), !FileManager.default.fileExists(atPath:finish.path), !Task.isCancelled {
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            if let canvas = findCanvas(window.contentView) {
                canvas.refreshLayers()
                if env["CAMCORD_EDITOR_NATIVE_EVENTS"] == "1" || env["CAMCORD_EDITOR_NATIVE_EVENT_SCENARIO"] == "1", playbackTask == nil {
                    playbackTask = Task { @MainActor in
                        do { try await playback.run(canvas:canvas,host:host,window:window,output:output,sentinel:sentinel) }
                        catch { playback.phase = "failed"; playback.error = String(describing:error) }
                    }
                }
                let imageFrame = canvas.convert(CGRect(origin:canvas.imageOrigin,size:canvas.imageSize),to:nil)
                let clipFrame = canvas.enclosingScrollView.map { $0.convert($0.contentView.frame,to:nil) } ?? .zero
                let hostClockSeconds = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                let state: [String:Any] = ["hostClockSeconds":hostClockSeconds,"hostClock":"CMClockGetHostTimeClock","pid":Int(ProcessInfo.processInfo.processIdentifier),"executablePath":Bundle.main.executableURL?.path ?? "", "windowID":window.windowNumber,"appActive":NSApp.isActive,"applicationRunning":NSApp.isRunning,"activationPolicy":NSApp.activationPolicy().rawValue,"finishedLaunchingBefore":finishedLaunchingBefore,"finishedLaunching":NSRunningApplication.current.isFinishedLaunching,"bundleIdentifier":Bundle.main.bundleIdentifier ?? "","key":window.isKeyWindow,"visible":window.isVisible,"backingScale":window.backingScaleFactor,"imageFrameInWindow":values(imageFrame),"clipFrameInWindow":values(clipFrame),"windowFrame":values(window.frame),"sourcePNG":output.appendingPathComponent("source.png").path,"sourceSize":[image.width,image.height],"sourcePixelMarkerROI":values(markerROI),"sourcePixelMarkerCoordinates":"CGImage/PNG source top-left pixels; detected checker rows","tool":session.tool.rawValue,"annotationCount":session.document?.edits.annotations.count ?? 0,"revision":session.revision,"baseGeneration":session.displayBaseGeneration,"displayRasterRequests":session.displayRasterRequests,"privacyDisplayFrames":canvas.privacyDisplayFrames,"privacyPatchComputations":canvas.privacyPatchComputations,"zoom":canvas.effectiveZoom,"displayedZoomPercent":session.displayedZoomPercent,"canUndo":session.canUndo,"canRedo":session.canRedo,"selectedID":session.selectedID?.uuidString ?? "","gestureCandidate":canvas.candidateAnnotation?.kind.rawValue ?? "none","inspector":session.showsBackgroundInspector,"error":session.error ?? "","firstResponder":String(describing:window.firstResponder),"eventPhase":playback.phase,"eventError":playback.error,"eventEvidence":"actual NSEvent production responder/canvas playback; customer CUA unmeasured","fixtureKind":"ordinary-production-window; actual CUA required"]
                let clipboardState: [String:Any] = ["clipboardBoardName":fixtureClipboard.pasteboard.name.rawValue,"clipboardPNGBytes":fixtureClipboard.pngByteCount,"clipboardPNGSHA256":fixtureClipboard.pngSHA256,"clipboardPublications":fixtureClipboard.publicationCount,"clipboardTarget":"unique-named-pasteboard; actual PNG publisher"]
                let clearance = (canvas.enclosingScrollView as? EditorScrollNSView)?.fitTopClearance ?? 0
                let colorWells = findColorWells(window.contentView)
                let controlMeasurements: [String:Any] = ["fitTopClearanceInClipPoints":clearance,"styleCapsuleMeasuredHeight":max(0,clearance-Theme.Space.m-Theme.Space.s),"fitTopInsetInSourcePoints":canvas.fitTopInset,"nativeCustomColorWellFramesInWindow":colorWells.map { values($0.convert($0.bounds,to:nil)) },"nativeCustomColorWellIntrinsicSizes":colorWells.map { [$0.intrinsicContentSize.width,$0.intrinsicContentSize.height] }]
                try JSONSerialization.data(withJSONObject:state.merging(clipboardState) { _,new in new }.merging(controlMeasurements) { _,new in new },options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("ready.json"),options:.atomic)
                let windows: [[String:Any]] = [["primaryID":window.windowNumber,"windowID":window.windowNumber,"pid":Int(ProcessInfo.processInfo.processIdentifier),"frame":values(window.frame),"key":window.isKeyWindow,"visible":window.isVisible,"title":window.title,"role":"primary"]]
                try JSONSerialization.data(withJSONObject:windows,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("windows.json"),options:.atomic)
            }
            try await Task.sleep(for:.milliseconds(100))
        }
        #expect(!NSApp.isActive)
    }
    private func findCanvas(_ view: NSView?) -> EditorCanvasNSView? {
        guard let view else { return nil }; if let canvas = view as? EditorCanvasNSView { return canvas }
        for child in view.subviews { if let result = findCanvas(child) { return result } }; return nil
    }
    private func findColorWells(_ view: NSView?) -> [EditorContinuousColorWell] {
        guard let view else { return [] }
        if let well = view as? EditorContinuousColorWell { return [well] }
        return view.subviews.flatMap { findColorWells($0) }
    }
    private func values(_ rect: CGRect) -> [CGFloat] { [rect.minX,rect.minY,rect.width,rect.height] }
    private func checkerROI(_ image:CGImage) throws -> CGRect {
        var rows:[Int] = []
        for y in 0..<image.height {
            guard let strip = image.cropping(to:CGRect(x:40,y:y,width:8,height:1)) else { continue }
            let c = try EditorRenderer.context(width:8,height:1); c.draw(strip,in:CGRect(x:0,y:0,width:8,height:1))
            let bytes = try #require(c.data?.assumingMemoryBound(to:UInt8.self))
            if bytes[0] == bytes[1], bytes[1] == bytes[2], bytes[16] == bytes[17], bytes[17] == bytes[18], abs(Int(bytes[0])-Int(bytes[16])) > 150 { rows.append(y) }
        }
        let first = try #require(rows.first), last = try #require(rows.last)
        #expect(rows.count == 60 && last-first == 59)
        return CGRect(x:40,y:first,width:880,height:last-first+1)
    }
    private func neutralImage() throws -> CGImage {
        let context = try EditorRenderer.context(width:960,height:600)
        context.setFillColor(CGColor(srgbRed:0.94,green:0.95,blue:0.97,alpha:1)); context.fill(CGRect(x:0,y:0,width:960,height:600))
        context.setFillColor(CGColor(srgbRed:0.12,green:0.16,blue:0.22,alpha:1)); context.fill(CGRect(x:40,y:40,width:880,height:180))
        context.setFillColor(CGColor(srgbRed:0.24,green:0.6,blue:0.46,alpha:1)); context.fill(CGRect(x:40,y:250,width:400,height:260))
        context.setFillColor(CGColor(srgbRed:0.9,green:0.76,blue:0.25,alpha:1)); context.fill(CGRect(x:470,y:250,width:450,height:260))
        for y in stride(from:520,to:580,by:4) { for x in stride(from:40,to:920,by:4) { context.setFillColor(CGColor(gray:((x+y)/4)%2 == 0 ? 0.1 : 0.9,alpha:1)); context.fill(CGRect(x:x,y:y,width:4,height:4)) } }
        return try #require(context.makeImage())
    }
}
@MainActor private final class EditorInteractionWindowDelegate: NSObject, NSWindowDelegate {
    let session: EditorSession
    init(session:EditorSession) { self.session = session }
    func windowWillReturnUndoManager(_ window:NSWindow) -> UndoManager? { session.editUndoManager }
}

/// Fixture Copy uses the production publication guard and PNG encoder while
/// ignoring the caller's destination, including the default general board.
@MainActor private final class EditorFixtureClipboard {
    let pasteboard = NSPasteboard.withUniqueName()
    private(set) var pngByteCount = 0
    private(set) var pngSHA256 = ""
    private(set) var publicationCount = 0
    func operations() -> EditorSession.ClipboardOperations {
        var operations = EditorSession.ClipboardOperations()
        operations.copyPNG = { [self] image,size,_,allowed in
            let published = await EditorClipboardPublisher.copyPNG(image,pointSize:size,to:pasteboard,shouldPublish:allowed)
            if published, let png = pasteboard.data(forType:.png) {
                pngByteCount = png.count
                pngSHA256 = SHA256.hash(data:png).map { String(format:"%02x",$0) }.joined()
                publicationCount += 1
            }
            return published
        }
        return operations
    }
}

@MainActor @Suite("Editor fixture publication isolation", .serialized)
struct EditorFixturePublicationTests {
    @Test("Owned fixture Copy encodes to its unique board and ignores an incoming destination")
    func isolatedCopy() async throws {
        let clipboard = EditorFixtureClipboard()
        let incoming = NSPasteboard.withUniqueName()
        defer { clipboard.pasteboard.releaseGlobally(); incoming.releaseGlobally() }
        incoming.setString("fixture incoming destination",forType:.string)
        let incomingChange = incoming.changeCount
        let context = try EditorRenderer.context(width:40,height:30)
        context.setFillColor(CGColor(gray:0.8,alpha:1)); context.fill(CGRect(x:0,y:0,width:40,height:30))
        let session = EditorSession(clipboard:clipboard.operations())
        defer { session.stop() }
        session.open(CapturedScreenshot(id:UUID(),image:try #require(context.makeImage()),pointSize:CGSize(width:20,height:15),kind:.screenshot,saveToDiskRequested:false))
        await session.waitForRendering()
        #expect(await session.copy(to:incoming))
        #expect(clipboard.pasteboard.name != .general)
        let png = try #require(clipboard.pasteboard.data(forType:.png))
        #expect(png == (try await session.flattened().png))
        #expect(clipboard.pngByteCount == png.count && clipboard.publicationCount == 1)
        #expect(clipboard.pngSHA256 == SHA256.hash(data:png).map { String(format:"%02x",$0) }.joined())
        #expect(incoming.changeCount == incomingChange && incoming.string(forType:.string) == "fixture incoming destination")
    }
}

/// Optional video stimulus through real production event handlers. These are
/// native-event fixture actions, not a customer CUA tour or model mutations.
@MainActor private final class EditorNativeEventPlayback {
    var phase = "idle"
    var error = ""
    private var sequence = 0
    func run<V: View>(canvas:EditorCanvasNSView, host:EditorUndoHostingController<V>, window:NSWindow, output:URL, sentinel:URL) async throws {
        let events = output.appendingPathComponent("native-events.jsonl")
        _ = FileManager.default.createFile(atPath:events.path,contents:nil)
        let log = try FileHandle(forWritingTo:events); defer { try? log.close() }
        func record(_ event:NSEvent?, _ kind:String) throws {
            let hostClockSeconds = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            let state:[String:Any] = ["hostClockSeconds":hostClockSeconds,"hostClock":"CMClockGetHostTimeClock","wallTime":Date().timeIntervalSince1970,"uptime":ProcessInfo.processInfo.systemUptime,"phase":phase,"kind":kind,"snapshotTiming":kind == "state-after-delivery" ? "after-delivery" : "before-delivery","eventType":event.map { Int($0.type.rawValue) } ?? -1,"eventTimestamp":event?.timestamp ?? 0,"windowID":window.windowNumber,"windowPoint":event.map { [$0.locationInWindow.x,$0.locationInWindow.y] } ?? [],"keyCode":event.flatMap { $0.type == .keyDown || $0.type == .keyUp ? Int($0.keyCode) : nil } ?? -1,"characters":event.flatMap { $0.type == .keyDown || $0.type == .keyUp ? $0.charactersIgnoringModifiers : nil } ?? "","modifiers":event?.modifierFlags.rawValue ?? 0,"revision":canvas.session?.revision ?? -1,"tool":canvas.session?.tool.rawValue ?? "","candidate":canvas.candidateAnnotation?.kind.rawValue ?? "none","baseGeneration":canvas.session?.displayBaseGeneration ?? -1,"displayRasterRequests":canvas.session?.displayRasterRequests ?? -1,"privacyDisplayFrames":canvas.privacyDisplayFrames,"privacyPatchComputations":canvas.privacyPatchComputations,"annotationCount":canvas.session?.document?.edits.annotations.count ?? -1,"canUndo":canvas.session?.canUndo ?? false,"canRedo":canvas.session?.canRedo ?? false,"appActive":NSApp.isActive,"keyWindow":window.isKeyWindow]
            try log.write(contentsOf:JSONSerialization.data(withJSONObject:state,options:[.sortedKeys])+Data([10]))
        }
        func active() throws {
            try Task.checkCancellation()
            guard FileManager.default.fileExists(atPath:sentinel.path), !FileManager.default.fileExists(atPath:output.appendingPathComponent("finish").path), !NSApp.isActive else { throw CocoaError(.userCancelled) }
        }
        func pause(_ milliseconds:Int) async throws { try active(); try await Task.sleep(for:.milliseconds(milliseconds)); try active() }
        func key(_ characters:String,code:UInt16,modifiers:NSEvent.ModifierFlags = []) throws -> NSEvent {
            try active()
            let event = try #require(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:code))
            try record(event,"key-event"); return event
        }
        func mouse(_ type:NSEvent.EventType,_ point:CGPoint) throws -> NSEvent {
            try active(); sequence += 1
            let event = try #require(NSEvent.mouseEvent(with:type,location:canvas.convert(point,to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:sequence,clickCount:1,pressure:1))
            try record(event,"mouse-event"); return event
        }
        func view(_ point:CGPoint) -> CGPoint { canvas.viewRect(CGRect(origin:point,size:.zero)).origin }
        func drag(_ from:CGPoint,_ to:CGPoint,_ name:String,commit:Bool = true) async throws {
            phase = name; canvas.mouseDown(with:try mouse(.leftMouseDown,from))
            try record(nil,"mouse-down-delivered")
            for frame in 1...60 {
                let t = CGFloat(frame)/60
                canvas.mouseDragged(with:try mouse(.leftMouseDragged,CGPoint(x:from.x+(to.x-from.x)*t,y:from.y+(to.y-from.y)*t)))
                if frame == 1 { try record(nil,"first-drag-delivered") }
                try record(nil,"state-after-delivery"); window.displayIfNeeded(); try await pause(16)
            }
            if commit { canvas.mouseUp(with:try mouse(.leftMouseUp,to)); try record(nil,"mouse-up-delivered") }
            try await pause(400)
        }
        canvas.keyDown(with:try key("1",code:18,modifiers:.command)); try await pause(350)
        phase = "actual100-awaiting-native-events-start"
        try Data("Clean source at Actual pixels; record window before touching native-events-start.\n".utf8).write(to:output.appendingPathComponent("native-events-ready"),options:.atomic)
        while !FileManager.default.fileExists(atPath:output.appendingPathComponent("native-events-start").path) { try await pause(100) }
        try await drag(view(CGPoint(x:90,y:170)),view(CGPoint(x:700,y:300)),"create-arrow-live")
        canvas.keyDown(with:try key("t",code:17)); try await pause(250)
        let middle = view(CGPoint(x:395,y:235))
        try await drag(middle,CGPoint(x:middle.x+50,y:middle.y+15),"move-arrow-with-text-tool")
        if let annotation = canvas.session?.selectedAnnotation {
            let end = canvas.handlePoints(for:annotation)[1]
            try await drag(end,CGPoint(x:end.x+80,y:end.y+20),"resize-arrow-endpoint")
        }
        phase = "native-command-undo"; #expect(host.performKeyEquivalent(with:try key("z",code:6,modifiers:.command))); try await pause(600)
        phase = "native-command-redo"; #expect(host.performKeyEquivalent(with:try key("z",code:6,modifiers:[.command,.shift]))); try await pause(600)
        phase = "native-delete"; canvas.keyDown(with:try key("\u{7f}",code:51)); try await pause(600)
        phase = "native-undo-delete"; #expect(host.performKeyEquivalent(with:try key("z",code:6,modifiers:.command))); try await pause(600)
        canvas.keyDown(with:try key("t",code:17)); try await pause(200)
        try await drag(view(CGPoint(x:80,y:350)),view(CGPoint(x:270,y:400)),"create-text-live")
        func textView(_ view:NSView?) -> EditorAnnotationTextView? {
            guard let view else { return nil }
            if let text = view as? EditorAnnotationTextView { return text }
            for child in view.subviews { if let found = textView(child) { return found } }
            return nil
        }
        phase = "type-annotation-text"
        let text = try #require(NSApp.windows.compactMap { textView($0.contentView) }.first)
        text.keyDown(with:try key("Review",code:15)); try record(nil,"text-input-delivered"); try await pause(400)
        #expect(canvas.session?.selectedAnnotation?.text == "Review")
        canvas.keyDown(with:try key("n",code:45)); try await pause(200)
        try await drag(view(CGPoint(x:330,y:350)),view(CGPoint(x:378,y:398)),"create-step-live")
        canvas.keyDown(with:try key("h",code:4)); try await pause(200)
        try await drag(view(CGPoint(x:450,y:370)),view(CGPoint(x:680,y:420)),"create-highlight-live")
        canvas.keyDown(with:try key("r",code:15)); try await pause(200)
        try await drag(view(CGPoint(x:60,y:440)),view(CGPoint(x:720,y:470)),"create-rectangle-live")
        if let annotation = canvas.session?.selectedAnnotation {
            let right = canvas.handlePoints(for:annotation)[3]
            try await drag(right,CGPoint(x:right.x+60,y:right.y),"resize-outside-right-handle")
        }
        canvas.keyDown(with:try key("b",code:11)); try await pause(200)
        try await drag(view(CGPoint(x:60,y:100)),view(CGPoint(x:200,y:145)),"create-blur-live")
        canvas.keyDown(with:try key("p",code:35)); try await pause(200)
        try await drag(view(CGPoint(x:240,y:100)),view(CGPoint(x:380,y:145)),"create-pixelate-live")
        canvas.keyDown(with:try key("x",code:7)); try await pause(200)
        try await drag(view(CGPoint(x:430,y:100)),view(CGPoint(x:570,y:145)),"create-redact-live")
        canvas.keyDown(with:try key("a",code:0)); try await pause(200)
        try await drag(view(CGPoint(x:780,y:150)),view(CGPoint(x:900,y:260)),"create-second-arrow-live")
        canvas.keyDown(with:try key("r",code:15)); try await pause(200)
        try await drag(view(CGPoint(x:760,y:520)),view(CGPoint(x:900,y:560)),"create-second-rectangle-live")
        #expect(canvas.session?.document?.edits.annotations.count == 10)
        canvas.keyDown(with:try key("a",code:0)); try await pause(250)
        try await drag(view(CGPoint(x:850,y:380)),view(CGPoint(x:900,y:460)),"escape-live-candidate",commit:false)
        canvas.keyDown(with:try key("\u{1b}",code:53)); try await pause(600)
        phase = "complete-native-event-evidence"
        try Data("native-event playback complete; customer CUA unmeasured\n".utf8).write(to:output.appendingPathComponent("native-events-complete"),options:.atomic)
    }
}
