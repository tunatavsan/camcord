import Foundation
import Testing

extension Trait where Self == ConditionTrait {
    /// Skips a test on hosted CI runners. They have a small virtual display, a software
    /// renderer and no permission to sample processes, so pixel, window-placement and sampler
    /// checks that pass on a Mac cannot pass there.
    static var needsLocalMac: Self {
        .disabled(if: ProcessInfo.processInfo.environment["CI"] == "true",
                  "Needs a real display, GPU and sampler; hosted CI runners have none of them")
    }
}
