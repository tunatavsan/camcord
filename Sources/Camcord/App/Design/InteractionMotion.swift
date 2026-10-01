import QuartzCore
import SwiftUI

extension Theme.Motion {
    static let interactionResponse = 0.35
    static let interactionDampingRatio = 0.85
    static let interaction = Animation.spring(response: interactionResponse, dampingFraction: interactionDampingRatio)

    /// The same physical spring for native layer motion and SwiftUI interaction.
    static func interactionSpring(keyPath: String, from: Any, to: Any) -> CASpringAnimation {
        let angularFrequency = 2 * Double.pi / interactionResponse
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = 1
        animation.stiffness = angularFrequency * angularFrequency
        animation.damping = 2 * interactionDampingRatio * angularFrequency
        animation.fromValue = from
        animation.toValue = to
        animation.duration = animation.settlingDuration
        return animation
    }
}
