import SwiftUI

/// Central theme definition for the VebeVoice app. All colors, spacings and materials
/// should be defined here to keep styling consistent and easy to evolve.
///
/// Tokens match TheVibeFather production CSS (`thevibefather.com` app stylesheet):
/// `--color-ground/panel*/line*/ink/muted/faint/void*/pink/blue/gold/mint/amber/rose`.
struct AppTheme {
    /// Canonical brand tokens from https://thevibefather.com (app CSS custom properties).
    enum VibeBrand {
        // MARK: Surfaces — full purple stack (app-wide violet, not neutral charcoal)
        static let ground = Color(hex: "0c0618")! // deepest void black-purple
        static let panel = Color(hex: "140a24")! // sidebar / content chrome
        static let panel2 = Color(hex: "1c1032")! // cards
        static let panel3 = Color(hex: "281648")! // elevated cards
        static let line = Color(hex: "3b2460")! // borders
        static let line2 = Color(hex: "4f3280")! // stronger separators

        // MARK: Light-mode purple surfaces
        static let lightGround = Color(hex: "f4f0ff")! // window
        static let lightPanel = Color(hex: "ebe4ff")! // content / sidebar
        static let lightPanel2 = Color(hex: "ffffff")! // cards (white with purple border)
        static let lightPanel3 = Color(hex: "f0ebff")! // elevated
        static let lightLine = Color(hex: "d4c4f5")! // borders
        static let lightLine2 = Color(hex: "b8a0ea")!

        // MARK: Text  (--color-ink / muted / faint)
        static let ink = Color(hex: "f3eeff")! // near-white with violet cast
        static let muted = Color(hex: "b5a8d9")! // lavender secondary
        static let faint = Color(hex: "8478ad")! // soft purple tertiary
        static let lightInk = Color(hex: "1a0b33")! // deep purple text on light
        static let lightMuted = Color(hex: "5b4580")!
        static let lightFaint = Color(hex: "7a6699")!

        // MARK: Accents — purple family is primary
        static let void = Color(hex: "8b5cf6")! // --color-void (primary brand purple)
        static let voidDeep = Color(hex: "7c3aed")! // --color-void-deep
        static let voidSoft = Color(hex: "a78bfa")! // --color-void-soft
        static let pink = Color(hex: "c084fc")! // softer purple-pink (less neon coral)
        static let blue = Color(hex: "a78bfa")! // map "blue" accent slot toward lilac
        static let mint = Color(hex: "a78bfa")! // success/status still purple-family
        static let amber = Color(hex: "c4b5fd")!
        static let rose = Color(hex: "e879f9")! // fuchsia for errors/alerts

        // MARK: Aliases used across the app (map to site names)
        static let bg = ground
        static let card = panel2
        static let elev = panel3
        static let accent = voidDeep
        static let accentHi = voidSoft

    }

    struct Palette {
        let windowBackground: Color
        let contentBackground: Color
        let sidebarBackground: Color
        let cardBackground: Color
        let elevatedCardBackground: Color
        let toolbarBackground: Color
        let cardBorder: Color
        let separator: Color
        let primaryText: Color
        let secondaryText: Color
        let tertiaryText: Color
        let accent: Color
        let warning: Color
        let success: Color
    }

    struct Typography {
        let sectionTitle: Font
        let body: Font
        let bodyStrong: Font
        let bodySmall: Font
        let bodySmallStrong: Font
        let caption: Font
        let captionStrong: Font
        let captionSmall: Font
        let tiny: Font
        let tinyStrong: Font
        let badge: Font
        let metricTiny: Font
        let sidebarItem: Font
        let sidebarSection: Font

        static let standard = Typography(
            sectionTitle: .system(size: 15, weight: .semibold),
            body: .system(size: 14, weight: .regular),
            bodyStrong: .system(size: 14, weight: .medium),
            bodySmall: .system(size: 13, weight: .regular),
            bodySmallStrong: .system(size: 13, weight: .medium),
            caption: .system(size: 12, weight: .regular),
            captionStrong: .system(size: 12, weight: .medium),
            captionSmall: .system(size: 11, weight: .regular),
            tiny: .system(size: 11, weight: .regular),
            tinyStrong: .system(size: 11, weight: .bold),
            badge: .system(size: 11, weight: .semibold),
            metricTiny: .system(size: 11, weight: .bold, design: .rounded),
            sidebarItem: .system(size: 14, weight: .regular),
            sidebarSection: .system(size: 12, weight: .medium)
        )
    }

    struct Metrics {
        struct Spacing {
            let xs: CGFloat
            let sm: CGFloat
            let md: CGFloat
            let lg: CGFloat
            let xl: CGFloat
            let xxl: CGFloat

            static let standard = Spacing(
                xs: 4,
                sm: 8,
                md: 12,
                lg: 16,
                xl: 22,
                xxl: 32
            )
        }

        struct CornerRadius {
            let sm: CGFloat
            let md: CGFloat
            let lg: CGFloat

            static let standard = CornerRadius(
                sm: 8,
                md: 12,
                lg: 18
            )
        }

        struct Shadow {
            let color: Color
            let radius: CGFloat
            let x: CGFloat
            let y: CGFloat
            let opacity: Double

            static let none = Shadow(color: .clear, radius: 0, x: 0, y: 0, opacity: 0)
        }

        struct CardSurface {
            struct Variant {
                let borderOpacity: Double
                let hoverBorderOpacity: Double
                let borderWidth: CGFloat
                let hoverShadowBoost: Double
            }

            let defaultPadding: CGFloat
            let standard: Variant
            let prominent: Variant
            let subtle: Variant

            static let defaults = CardSurface(
                defaultPadding: 16,
                standard: Variant(
                    borderOpacity: 0.55,
                    hoverBorderOpacity: 0.75,
                    borderWidth: 1,
                    hoverShadowBoost: 0.0
                ),
                prominent: Variant(
                    borderOpacity: 0.65,
                    hoverBorderOpacity: 0.85,
                    borderWidth: 1,
                    hoverShadowBoost: 0.0
                ),
                subtle: Variant(
                    borderOpacity: 0.40,
                    hoverBorderOpacity: 0.55,
                    borderWidth: 1,
                    hoverShadowBoost: 0.0
                )
            )
        }

        struct OnboardingSurface {
            struct Landing {
                let contentWidth: CGFloat
                let heroPadding: CGFloat
                let sectionSpacing: CGFloat
            }

            let landing: Landing

            static let standard = OnboardingSurface(
                landing: Landing(
                    contentWidth: 820,
                    heroPadding: 28,
                    sectionSpacing: 16
                )
            )
        }

        struct Window {
            let mainMinWidth: CGFloat
            let mainMinHeight: CGFloat
            let onboardingMinWidth: CGFloat
            let onboardingMinHeight: CGFloat

            static let standard = Window(
                mainMinWidth: 800,
                mainMinHeight: 500,
                onboardingMinWidth: 940,
                onboardingMinHeight: 700
            )
        }

        let spacing: Spacing
        let corners: CornerRadius
        let cardSurface: CardSurface
        let onboardingSurface: OnboardingSurface
        let window: Window
        let cardShadow: Shadow
        let elevatedCardShadow: Shadow
    }

    struct Materials {
        let window: Material
        let card: Material
    }

    let palette: Palette
    let typography: Typography
    let metrics: Metrics
    let materials: Materials

    static func adaptive(accent: Color, colorScheme: ColorScheme) -> AppTheme {
        switch colorScheme {
        case .light:
            return .light(accent: accent)
        case .dark:
            return .dark(accent: accent)
        @unknown default:
            return .dark(accent: accent)
        }
    }

    /// Light theme — lavender purple surfaces (not system gray).
    static func light(accent: Color) -> AppTheme {
        AppTheme(
            palette: Palette(
                windowBackground: VibeBrand.lightGround,
                contentBackground: VibeBrand.lightPanel,
                sidebarBackground: VibeBrand.lightPanel,
                cardBackground: VibeBrand.lightPanel2,
                elevatedCardBackground: VibeBrand.lightPanel3,
                toolbarBackground: VibeBrand.lightPanel,

                cardBorder: VibeBrand.lightLine,
                separator: VibeBrand.lightLine2,
                primaryText: VibeBrand.lightInk,
                secondaryText: VibeBrand.lightMuted,
                tertiaryText: VibeBrand.lightFaint,
                accent: accent,
                warning: VibeBrand.voidDeep,
                success: VibeBrand.void
            ),
            typography: .standard,
            metrics: Metrics(
                spacing: .standard,
                corners: .standard,
                cardSurface: .defaults,
                onboardingSurface: .standard,
                window: .standard,
                cardShadow: .none,
                elevatedCardShadow: .none
            ),
            materials: Materials(
                window: .thinMaterial,
                // Flat solid cards — materials add frosted glow that reads muddy on settings.
                card: .regularMaterial
            )
        )
    }

    /// Dark-forward VebeVoice theme — full purple void stack.
    static func dark(accent: Color) -> AppTheme {
        AppTheme(
            palette: Palette(
                windowBackground: VibeBrand.ground,
                contentBackground: VibeBrand.panel,
                sidebarBackground: VibeBrand.panel,
                cardBackground: VibeBrand.panel2,
                elevatedCardBackground: VibeBrand.panel3,
                toolbarBackground: VibeBrand.panel,

                cardBorder: VibeBrand.line,
                separator: VibeBrand.line2,
                primaryText: VibeBrand.ink,
                secondaryText: VibeBrand.muted,
                tertiaryText: VibeBrand.faint,
                accent: accent,
                warning: VibeBrand.voidSoft,
                success: VibeBrand.void
            ),
            typography: .standard,
            metrics: Metrics(
                spacing: .standard,
                corners: .standard,
                cardSurface: .defaults,
                onboardingSurface: .standard,
                window: .standard,
                // Flat, modern — no purple bloom / heavy drop shadows on cards.
                cardShadow: .none,
                elevatedCardShadow: .none
            ),
            materials: Materials(
                window: .thinMaterial,
                card: .regularMaterial
            )
        )
    }

    static let dark = AppTheme.dark(accent: .vibeAccent)
}

// MARK: - Helpers
