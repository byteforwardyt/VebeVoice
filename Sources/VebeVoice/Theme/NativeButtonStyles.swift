import SwiftUI

enum VibeInteractionVisuals {
    static let hoverScale: CGFloat = 1.02
    static let pressedScale: CGFloat = 0.97
    static let hoverAnimation: Animation = .spring(response: 0.22, dampingFraction: 0.82)
    static let pressedAnimation: Animation = .spring(response: 0.2, dampingFraction: 0.8)

    static func scale(isPressed: Bool, isHovered: Bool) -> CGFloat {
        if isPressed { return self.pressedScale }
        return isHovered ? self.hoverScale : 1
    }
}

enum VibeButtonRole {
    case primary
    case secondary
    case glass
    case compact
    case accent
    case destructive
    case inline
}

enum VibeButtonSize: Equatable {
    case compact
    case small
    case medium
    case large

    var controlHeight: CGFloat {
        switch self {
        case .compact:
            return 34
        case .small:
            return 32
        case .medium:
            return 36
        case .large:
            return 44
        }
    }

    var accentCompact: Bool {
        self == .small || self == .compact
    }
}

extension View {
    @ViewBuilder
    func vibeButton(
        _ role: VibeButtonRole,
        size: VibeButtonSize = .medium,
        isRecording: Bool = false
    ) -> some View {
        switch role {
        case .primary:
            self.buttonStyle(PremiumButtonStyle(isRecording: isRecording, height: size.controlHeight))
        case .secondary:
            self.buttonStyle(SecondaryButtonStyle(height: size.controlHeight))
        case .glass:
            self.buttonStyle(GlassButtonStyle(height: size.controlHeight))
        case .compact:
            self.buttonStyle(CompactButtonStyle(height: size.controlHeight))
        case .accent:
            self.buttonStyle(AccentButtonStyle(compact: size.accentCompact))
        case .destructive:
            self.buttonStyle(AccentButtonStyle(compact: size.accentCompact, tone: AppTheme.VibeBrand.rose))
        case .inline:
            self.buttonStyle(InlineButtonStyle())
        }
    }

}

// MARK: - Primary (Prominent) Button

struct GlassButtonStyle: ButtonStyle {
    var height: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        GlassButton(configuration: configuration, height: self.height)
    }

    private struct GlassButton: View {
        @Environment(\.theme) private var theme
        @State private var isHovered = false
        let configuration: ButtonStyle.Configuration
        let height: CGFloat?

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
        }

        var body: some View {
            self.configuration.label
                .fontWeight(.semibold)
                .padding(.horizontal, self.theme.metrics.spacing.lg)
                .padding(.vertical, self.theme.metrics.spacing.sm)
                .frame(height: self.height ?? 36)
                .foregroundStyle(self.theme.palette.primaryText)
                .background(self.theme.materials.card, in: self.shape)
                .background(
                    self.shape
                        .fill(self.theme.palette.cardBackground)
                        .overlay(
                            self.shape.stroke(
                                self.theme.palette.cardBorder.opacity(self.isHovered ? 0.45 : 0.25),
                                lineWidth: 1
                            )
                        )
                )
                .overlay(
                    self.shape
                        .stroke(self.theme.palette.accent.opacity(self.isHovered ? 0.25 : 0.1), lineWidth: 1)
                        .blendMode(.plusLighter)
                )
                .shadow(
                    color: self.theme.palette.cardBorder.opacity(self.isHovered ? 0.45 : 0.22),
                    radius: self.isHovered ? self.theme.metrics.cardShadow.radius : max(self.theme.metrics.cardShadow.radius - 3, 2),
                    x: 0,
                    y: self.isHovered ? self.theme.metrics.cardShadow.y : self.theme.metrics.cardShadow.y - 2
                )
                .scaleEffect(VibeInteractionVisuals.scale(isPressed: self.configuration.isPressed, isHovered: self.isHovered))
                .animation(VibeInteractionVisuals.hoverAnimation, value: self.isHovered)
                .animation(VibeInteractionVisuals.pressedAnimation, value: self.configuration.isPressed)
                .onHover { self.isHovered = $0 }
        }
    }
}

// MARK: - Primary Accent Button

struct PremiumButtonStyle: ButtonStyle {
    var isRecording: Bool = false
    var height: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        PrimaryButton(configuration: configuration, isRecording: self.isRecording, height: self.height)
    }

    private struct PrimaryButton: View {
        @Environment(\.theme) private var theme
        @State private var isHovered = false
        let configuration: ButtonStyle.Configuration
        let isRecording: Bool
        let height: CGFloat

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg, style: .continuous)
        }

        private var baseGradient: LinearGradient {
            if self.isRecording {
                return LinearGradient(
                    colors: [
                        AppTheme.VibeBrand.rose,
                        AppTheme.VibeBrand.pink.opacity(0.88),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            // TheVibeFather wordmark-style void gradient
            return LinearGradient(
                colors: [
                    AppTheme.VibeBrand.voidSoft,
                    AppTheme.VibeBrand.void,
                    AppTheme.VibeBrand.voidDeep,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        var body: some View {
            self.configuration.label
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .frame(height: self.height)
                .foregroundStyle(Color.white)
                .background(
                    self.shape
                        .fill(self.baseGradient)
                        .overlay(
                            self.shape.stroke(
                                Color.white.opacity(self.isHovered ? 0.38 : 0.18),
                                lineWidth: 1
                            )
                        )
                        .overlay(
                            self.shape
                                .stroke(AppTheme.VibeBrand.voidSoft.opacity(self.isHovered ? 0.35 : 0.12), lineWidth: 1)
                                .blendMode(.plusLighter)
                        )
                )
                .shadow(
                    color: (self.isRecording ? AppTheme.VibeBrand.rose : AppTheme.VibeBrand.void)
                        .opacity(self.isHovered ? 0.55 : 0.32),
                    radius: self.isHovered ? self.theme.metrics.elevatedCardShadow.radius + 2 : max(self.theme.metrics.cardShadow.radius, 4),
                    x: 0,
                    y: self.isHovered ? self.theme.metrics.elevatedCardShadow.y : self.theme.metrics.cardShadow.y
                )
                .scaleEffect(VibeInteractionVisuals.scale(isPressed: self.configuration.isPressed, isHovered: self.isHovered))
                .animation(VibeInteractionVisuals.hoverAnimation, value: self.isHovered)
                .animation(VibeInteractionVisuals.pressedAnimation, value: self.configuration.isPressed)
                .onHover { self.isHovered = $0 }
        }
    }
}

// MARK: - Secondary Button

struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 42

    func makeBody(configuration: Configuration) -> some View {
        SecondaryButton(configuration: configuration, height: self.height)
    }

    private struct SecondaryButton: View {
        @Environment(\.theme) private var theme
        @State private var isHovered = false
        let configuration: ButtonStyle.Configuration
        let height: CGFloat

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.lg, style: .continuous)
        }

        var body: some View {
            self.configuration.label
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .frame(height: self.height)
                .foregroundStyle(self.theme.palette.primaryText)
                .background(self.theme.materials.card, in: self.shape)
                .background(
                    self.shape
                        .fill(self.theme.palette.cardBackground)
                        .overlay(
                            self.shape.stroke(
                                self.theme.palette.cardBorder.opacity(self.isHovered ? 0.45 : 0.25),
                                lineWidth: 1
                            )
                        )
                )
                .shadow(
                    color: self.theme.palette.cardBorder.opacity(self.isHovered ? 0.35 : 0.15),
                    radius: self.isHovered ? self.theme.metrics.cardShadow.radius : max(self.theme.metrics.cardShadow.radius - 4, 1),
                    x: 0,
                    y: self.isHovered ? self.theme.metrics.cardShadow.y : self.theme.metrics.cardShadow.y - 2
                )
                .scaleEffect(VibeInteractionVisuals.scale(isPressed: self.configuration.isPressed, isHovered: self.isHovered))
                .animation(VibeInteractionVisuals.hoverAnimation, value: self.isHovered)
                .animation(VibeInteractionVisuals.pressedAnimation, value: self.configuration.isPressed)
                .onHover { self.isHovered = $0 }
        }
    }
}

// MARK: - Compact Button

struct CompactButtonStyle: ButtonStyle {
    var isReady: Bool = false
    var foreground: Color? = nil
    var borderColor: Color? = nil
    var height: CGFloat = 34

    func makeBody(configuration: Configuration) -> some View {
        CompactButton(
            configuration: configuration,
            isReady: self.isReady,
            foreground: self.foreground,
            borderColor: self.borderColor,
            height: self.height
        )
    }

    private struct CompactButton: View {
        @Environment(\.theme) private var theme
        @State private var isHovered = false
        let configuration: ButtonStyle.Configuration
        let isReady: Bool
        let foreground: Color?
        let borderColor: Color?
        let height: CGFloat

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous)
        }

        var body: some View {
            let border = self.borderColor ?? (self.isReady ? self.theme.palette.accent : self.theme.palette.cardBorder)
            let foregroundColor = self.foreground ?? self.theme.palette.primaryText
            let borderOpacity = self.borderColor == nil
                ? (self.isHovered ? 0.56 : 0.38)
                : (self.isHovered ? 0.64 : 0.48)

            self.configuration.label
                .fontWeight(.medium)
                .padding(.horizontal, self.theme.metrics.spacing.md)
                .frame(height: self.height)
                .foregroundStyle(foregroundColor)
                .background(self.theme.materials.card, in: self.shape)
                .background(
                    self.shape
                        .fill(self.theme.palette.cardBackground)
                        .overlay(
                            self.shape.stroke(
                                border.opacity(borderOpacity),
                                lineWidth: 1
                            )
                        )
                )
                .shadow(
                    color: border.opacity(self.isHovered ? 0.18 : 0.06),
                    radius: self.isHovered ? 4 : 1.5,
                    x: 0,
                    y: self.isHovered ? 1 : 0.5
                )
                .scaleEffect(VibeInteractionVisuals.scale(isPressed: self.configuration.isPressed, isHovered: self.isHovered))
                .animation(VibeInteractionVisuals.hoverAnimation, value: self.isHovered)
                .animation(VibeInteractionVisuals.pressedAnimation, value: self.configuration.isPressed)
                .onHover { self.isHovered = $0 }
        }
    }
}

// MARK: - Accent Filled Button (Solid accent background)

struct AccentButtonStyle: ButtonStyle {
    var compact: Bool = false
    var tone: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        AccentButton(configuration: configuration, compact: self.compact, tone: self.tone)
    }

    private struct AccentButton: View {
        @Environment(\.theme) private var theme
        @State private var isHovered = false
        let configuration: ButtonStyle.Configuration
        let compact: Bool
        let tone: Color?

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: self.compact ? 8 : self.theme.metrics.corners.md, style: .continuous)
        }

        var body: some View {
            let tone = self.tone ?? self.theme.palette.accent
            self.configuration.label
                .fontWeight(.semibold)
                .padding(.horizontal, self.compact ? 12 : self.theme.metrics.spacing.lg)
                .padding(.vertical, self.compact ? 8 : self.theme.metrics.spacing.md)
                .frame(minHeight: self.compact ? 32 : 36)
                .foregroundStyle(Color.white)
                .background(
                    self.shape
                        .fill(
                            LinearGradient(
                                colors: [
                                    tone,
                                    tone.opacity(0.85),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .overlay(
                    self.shape
                        .stroke(Color.white.opacity(self.isHovered ? 0.3 : 0.15), lineWidth: 1)
                )
                .shadow(
                    color: tone.opacity(self.isHovered ? 0.5 : 0.3),
                    radius: self.isHovered ? 6 : 4,
                    x: 0,
                    y: self.isHovered ? 3 : 2
                )
                .scaleEffect(VibeInteractionVisuals.scale(isPressed: self.configuration.isPressed, isHovered: self.isHovered))
                .animation(VibeInteractionVisuals.hoverAnimation, value: self.isHovered)
                .animation(VibeInteractionVisuals.pressedAnimation, value: self.configuration.isPressed)
                .onHover { self.isHovered = $0 }
        }
    }
}

// MARK: - Inline Button

struct InlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        InlineButton(configuration: configuration)
    }

    private struct InlineButton: View {
        @Environment(\.theme) private var theme
        @State private var isHovered = false
        let configuration: ButtonStyle.Configuration

        private var shape: Capsule {
            Capsule()
        }

        var body: some View {
            self.configuration.label
                .font(.caption)
                .fontWeight(.medium)
                .padding(.horizontal, self.theme.metrics.spacing.md)
                .padding(.vertical, self.theme.metrics.spacing.xs)
                .foregroundStyle(Color.white)
                .background(
                    self.shape
                        .fill(self.theme.palette.accent.opacity(self.isHovered ? 0.9 : 0.8))
                )
                .shadow(
                    color: self.theme.palette.accent.opacity(self.isHovered ? 0.45 : 0.25),
                    radius: self.isHovered ? 6 : 3,
                    x: 0,
                    y: self.isHovered ? 3 : 1
                )
                .scaleEffect(VibeInteractionVisuals.scale(isPressed: self.configuration.isPressed, isHovered: self.isHovered))
                .animation(VibeInteractionVisuals.hoverAnimation, value: self.isHovered)
                .animation(VibeInteractionVisuals.pressedAnimation, value: self.configuration.isPressed)
                .onHover { self.isHovered = $0 }
        }
    }
}

// MARK: - Native Form Row Style


// MARK: - Square Icon Button Style (no horizontal padding, fixed square)

struct SquareIconButtonStyle: ButtonStyle {
    var foreground: Color? = nil
    var borderColor: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        SquareIconButton(
            configuration: configuration,
            foreground: self.foreground,
            borderColor: self.borderColor
        )
    }

    private struct SquareIconButton: View {
        @Environment(\.theme) private var theme
        @State private var isHovered = false
        let configuration: ButtonStyle.Configuration
        let foreground: Color?
        let borderColor: Color?

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm, style: .continuous)
        }

        var body: some View {
            let border = self.borderColor ?? self.theme.palette.cardBorder
            let borderOpacity = self.borderColor == nil
                ? (self.isHovered ? 0.8 : 0.6)
                : (self.isHovered ? 0.84 : 0.68)
            let foregroundColor = self.foreground ?? self.theme.palette.primaryText

            self.configuration.label
                .foregroundStyle(foregroundColor)
                .background(self.theme.materials.card, in: self.shape)
                .background(
                    self.shape
                        .fill(self.theme.palette.cardBackground)
                        .overlay(
                            self.shape.stroke(
                                border.opacity(borderOpacity),
                                lineWidth: 1
                            )
                        )
                )
                .shadow(
                    color: border.opacity(self.isHovered ? 0.18 : 0.06),
                    radius: self.isHovered ? 4 : 1.5,
                    x: 0,
                    y: self.isHovered ? 1 : 0.5
                )
                .scaleEffect(VibeInteractionVisuals.scale(isPressed: self.configuration.isPressed, isHovered: self.isHovered))
                .animation(VibeInteractionVisuals.hoverAnimation, value: self.isHovered)
                .animation(VibeInteractionVisuals.pressedAnimation, value: self.configuration.isPressed)
                .onHover { self.isHovered = $0 }
        }
    }
}
