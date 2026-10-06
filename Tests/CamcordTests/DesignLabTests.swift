import Foundation
import Testing

@testable import Camcord

/// The Design Lab renders each design direction's key tokens natively; this keeps the set of
/// lab directions fixed and each one's tokens sane, Graphite first.
@MainActor
@Suite("Design Lab")
struct DesignLabTests {
    @Test("one lab direction per design direction, Graphite first")
    func directionsMatchThePrototypes() {
        #expect(LabDirection.all.map(\.id) == ["graphite", "frost", "console", "candy"])
        #expect(Set(LabDirection.all.map(\.id)).count == LabDirection.all.count)
        for direction in LabDirection.all {
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
