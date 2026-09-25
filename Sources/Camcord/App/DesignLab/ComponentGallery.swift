import SwiftUI

/// The Design Lab's component page (RUN UI-2 P1.2): every kit component in all its states.
struct ComponentGallery: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xxl) {
                Text(verbatim: "The component kit arrives in P1.2.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.ink2.color)
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.Palette.window.color)
    }
}
