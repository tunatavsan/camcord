import Foundation
import Testing

@testable import Camcord

/// The Design Lab (RUN UI-1 C2) renders each C1 direction's key tokens natively; this keeps
/// the two in step: one lab direction per published direction, the owner's reference first.
@MainActor
@Suite("Design Lab")
struct DesignLabTests {
    private static let directions = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/design/directions")

    @Test("one lab direction per design direction, Graphite (the owner's reference) first")
    func directionsMatchThePrototypes() {
        #expect(LabDirection.all.map(\.id) == ["graphite", "frost", "console", "candy"])
        #expect(Set(LabDirection.all.map(\.id)).count == LabDirection.all.count)
        for direction in LabDirection.all {
            let rationale = Self.directions.appendingPathComponent("\(direction.id).md")
            let prototype = Self.directions.appendingPathComponent("\(direction.id)/index.html")
            #expect(FileManager.default.fileExists(atPath: rationale.path), "\(direction.id).md")
            #expect(FileManager.default.fileExists(atPath: prototype.path), "\(direction.id)/index.html")
            #expect(direction.surfaceRadius > 0 && direction.controlRadius > 0 && direction.spacing > 0)
            #expect(direction.arrivalScale > 0.8 && direction.arrivalScale <= 1)
            #expect(!direction.backdrop.isEmpty)
        }
        #expect(LabDirection.graphite.prefersDark)
        #expect(LabDirection.console.prefersDark)
        #expect(!LabDirection.frost.prefersDark)
        // Console's personality: no blur arrival; Frost and Graphite arrive from blur.
        #expect(LabDirection.console.arrivalBlur == 0)
        #expect(LabDirection.frost.arrivalBlur > 0 && LabDirection.graphite.arrivalBlur > 0)
    }

    @Test("the frame meter says nothing until it has measured")
    func meterStartsEmpty() {
        #expect(FrameMeter().summary == "—")
    }
}
