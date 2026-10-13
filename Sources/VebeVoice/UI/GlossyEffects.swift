import SwiftUI

struct ButtonHoverModifier: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(self.isHovered ? VibeInteractionVisuals.hoverScale : 1.0)
            // No accent glow on hover — keeps Settings and controls flat/modern.
            .onHover { hovering in
                self.isHovered = hovering
            }
            .animation(VibeInteractionVisuals.hoverAnimation, value: self.isHovered)
    }
}
