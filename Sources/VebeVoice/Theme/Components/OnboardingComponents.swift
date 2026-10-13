import AppKit
import SwiftUI

struct VibeOnboardingLandingHero<Actions: View>: View {
    @Environment(\.theme) private var theme

    let eyebrow: String
    let title: String
    let accentTitle: String
    let firstDetail: String
    let secondDetail: String
    let actions: Actions

    init(
        eyebrow: String,
        title: String,
        accentTitle: String,
        firstDetail: String,
        secondDetail: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.accentTitle = accentTitle
        self.firstDetail = firstDetail
        self.secondDetail = secondDetail
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 0) {
            VibeOnboardingAppIconMark()
                .padding(.bottom, self.eyebrow.isEmpty ? 40 : 26)

            if !self.eyebrow.isEmpty {
                Text(self.eyebrow)
                    .font(.system(size: 14, weight: .bold))
                    .tracking(4.2)
                    .foregroundStyle(VibeOnboardingLandingColors.blue.opacity(0.72))
                    .textCase(.uppercase)
                    .padding(.bottom, 16)
            }

            VStack(spacing: 4) {
                Text(self.title)
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.82)

                Text(self.accentTitle)
                    .font(.system(size: 50, weight: .semibold))
                    .italic()
                    .foregroundStyle(VibeOnboardingLandingColors.blue)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.76)
            }
            .lineLimit(1)
            .shadow(color: .black.opacity(0.34), radius: 10, x: 0, y: 5)
            .padding(.bottom, 28)

            VStack(spacing: 8) {
                Text(self.firstDetail)
                Text(self.secondDetail)
            }
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.70))
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.bottom, 42)

            self.actions
        }
        .padding(.horizontal, self.theme.metrics.onboardingSurface.landing.heroPadding)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct VibeOnboardingLandingBackdrop: View {
    let glowCenter: UnitPoint

    init(glowCenter: UnitPoint = UnitPoint(x: 0.5, y: 0.18)) {
        self.glowCenter = glowCenter
    }

    var body: some View {
        ZStack {
            // TheVibeFather void: #0d0a14
            AppTheme.VibeBrand.bg

            RadialGradient(
                colors: [
                    AppTheme.VibeBrand.accent.opacity(0.28),
                    AppTheme.VibeBrand.accentHi.opacity(0.14),
                    AppTheme.VibeBrand.pink.opacity(0.08),
                    .clear,
                ],
                center: self.glowCenter,
                startRadius: 0,
                endRadius: 620
            )

            RadialGradient(
                colors: [
                    Color.white.opacity(0.03),
                    .clear,
                ],
                center: .center,
                startRadius: 0,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
    }
}

struct VibeOnboardingCompactProgress: View {
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            let clampedValue = min(max(self.value, 0), 1)
            let width = proxy.size.width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))

                Capsule()
                    .fill(VibeOnboardingLandingColors.blue)
                    .frame(width: width * clampedValue)
                    .shadow(color: VibeOnboardingLandingColors.blue.opacity(0.38), radius: 8, x: 0, y: 0)
            }
        }
        .frame(width: 292, height: 4)
        .accessibilityHidden(true)
    }
}

struct VibeOnboardingCompactAppIconMark: View {
    private static let appIconImage: NSImage = {
        if let mark = NSImage(named: "VebeVoiceMark") { return mark }
        if let app = NSApplication.shared.applicationIconImage { return app }
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }()

    let size: CGFloat

    init(size: CGFloat = 66) {
        self.size = size
    }

    var body: some View {
        Image(nsImage: Self.appIconImage)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: self.size, height: self.size)
            .shadow(color: VibeOnboardingLandingColors.blue.opacity(0.45), radius: 24, x: 0, y: 0)
            .shadow(color: Color.black.opacity(0.42), radius: 14, x: 0, y: 9)
            .accessibilityHidden(true)
    }
}

struct VibeOnboardingLandingHoverTracker: NSViewRepresentable {
    let onMove: (CGPoint, CGSize) -> Void
    let onExit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onMove: self.onMove, onExit: self.onExit)
    }

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        context.coordinator.onMove = self.onMove
        context.coordinator.onExit = self.onExit
        view.coordinator = context.coordinator
    }

    final class Coordinator {
        var onMove: (CGPoint, CGSize) -> Void
        var onExit: () -> Void

        init(onMove: @escaping (CGPoint, CGSize) -> Void, onExit: @escaping () -> Void) {
            self.onMove = onMove
            self.onExit = onExit
        }
    }

    final class TrackingView: NSView {
        weak var coordinator: Coordinator?
        private var trackingArea: NSTrackingArea?

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            if let trackingArea {
                self.removeTrackingArea(trackingArea)
            }

            let options: NSTrackingArea.Options = [
                .activeInKeyWindow,
                .inVisibleRect,
                .mouseEnteredAndExited,
                .mouseMoved,
            ]
            let trackingArea = NSTrackingArea(rect: .zero, options: options, owner: self)
            self.addTrackingArea(trackingArea)
            self.trackingArea = trackingArea
        }

        override func mouseEntered(with event: NSEvent) {
            self.report(event)
        }

        override func mouseMoved(with event: NSEvent) {
            self.report(event)
        }

        override func mouseExited(with event: NSEvent) {
            self.coordinator?.onExit()
        }

        private func report(_ event: NSEvent) {
            let location = self.convert(event.locationInWindow, from: nil)
            self.coordinator?.onMove(location, self.bounds.size)
        }
    }
}

struct VibeOnboardingLandingPrimaryButton: NSViewRepresentable {
    static let size = CGSize(width: 236, height: 56)

    let title: String
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: self.action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = LandingPrimaryNSButton()
        button.target = context.coordinator
        button.action = #selector(Coordinator.performAction)
        button.setButtonType(.momentaryPushIn)
        button.isBordered = false
        button.wantsLayer = true
        button.focusRingType = .none
        button.keyEquivalent = "\r"
        button.keyEquivalentModifierMask = []
        button.setAccessibilityLabel(self.title)
        button.update(title: self.title, isHighlighted: false)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = self.action

        guard let button = button as? LandingPrimaryNSButton else {
            button.title = self.title
            button.setAccessibilityLabel(self.title)
            return
        }

        button.setAccessibilityLabel(self.title)
        button.update(title: self.title, isHighlighted: button.isHighlighted)
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performAction() {
            self.action()
        }
    }
}

private final class LandingPrimaryNSButton: NSButton {
    // TheVibeFather --color-void-deep / --color-void / --color-void-soft
    private static let normalColor = NSColor(srgbRed: 0.486, green: 0.227, blue: 0.929, alpha: 1.0) // #7c3aed
    private static let highlightedColor = NSColor(srgbRed: 0.420, green: 0.180, blue: 0.820, alpha: 1.0)
    private static let hoverColor = NSColor(srgbRed: 0.545, green: 0.361, blue: 0.965, alpha: 1.0) // #8b5cf6
    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    override var isHighlighted: Bool {
        didSet {
            self.update(title: self.title, isHighlighted: self.isHighlighted)
        }
    }

    override var intrinsicContentSize: NSSize {
        VibeOnboardingLandingPrimaryButton.size
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard self.isEnabled, !self.isHidden, self.alphaValue > 0, self.bounds.contains(point) else {
            return nil
        }

        return self
    }

    override func layout() {
        super.layout()
        self.layer?.cornerRadius = self.bounds.height / 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            self.removeTrackingArea(trackingArea)
        }

        let options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect]
        let trackingArea = NSTrackingArea(rect: .zero, options: options, owner: self)
        self.addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        self.isHovering = true
        self.update(title: self.title, isHighlighted: self.isHighlighted)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        self.isHovering = false
        self.update(title: self.title, isHighlighted: self.isHighlighted)
    }

    func update(title: String, isHighlighted: Bool) {
        self.title = title
        self.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
        )
        self.alignment = .center
        self.layer?.masksToBounds = false
        self.layer?.backgroundColor = self.backgroundColor(isHighlighted: isHighlighted).cgColor
        self.layer?.cornerRadius = self.bounds.height > 0 ? self.bounds.height / 2 : 28
        self.layer?.shadowColor = Self.normalColor.withAlphaComponent(0.34).cgColor
        self.layer?.shadowOpacity = isHighlighted ? 0.20 : 0.34
        self.layer?.shadowRadius = isHighlighted ? 8 : 14
        self.layer?.shadowOffset = NSSize(width: 0, height: isHighlighted ? 4 : 7)
    }

    private func backgroundColor(isHighlighted: Bool) -> NSColor {
        if isHighlighted {
            return Self.highlightedColor
        }

        return self.isHovering ? Self.hoverColor : Self.normalColor
    }
}

private struct VibeOnboardingAppIconMark: View {
    private static let appIconImage: NSImage = {
        if let mark = NSImage(named: "VebeVoiceMark") { return mark }
        if let app = NSApplication.shared.applicationIconImage { return app }
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }()

    var body: some View {
        ZStack {
            Circle()
                .fill(VibeOnboardingLandingColors.blue.opacity(0.28))
                .blur(radius: 42)
                .frame(width: 188, height: 188)
                .offset(y: -16)

            VibeOnboardingPortalGlow()
                .offset(y: 58)

            Image(nsImage: Self.appIconImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 116, height: 116)
                .shadow(color: Color.black.opacity(0.56), radius: 20, x: 0, y: 15)
                .shadow(color: VibeOnboardingLandingColors.blue.opacity(0.58), radius: 36, x: 0, y: 0)
        }
        .frame(width: 360, height: 176)
        .accessibilityHidden(true)
    }
}

private struct VibeOnboardingPortalGlow: View {
    var body: some View {
        ZStack {
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.74),
                            VibeOnboardingLandingColors.blue.opacity(0.64),
                            VibeOnboardingLandingColors.blue.opacity(0.05),
                            .clear,
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 112
                    )
                )
                .blur(radius: 7)
                .frame(width: 230, height: 25)

            Ellipse()
                .stroke(VibeOnboardingLandingColors.blue.opacity(0.42), lineWidth: 3)
                .blur(radius: 1.4)
                .frame(width: 326, height: 35)

            Ellipse()
                .stroke(VibeOnboardingLandingColors.blue.opacity(0.24), lineWidth: 1.4)
                .frame(width: 260, height: 22)
        }
    }
}

enum VibeOnboardingLandingColors {
    /// Primary onboarding accent — TheVibeFather void purple stack.
    static let blue = AppTheme.VibeBrand.voidDeep // --color-void-deep
}

