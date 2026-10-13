import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class DictionaryCorrectionOverlayController {
    static let shared = DictionaryCorrectionOverlayController()

    private static let displayDurationNanoseconds: UInt64 = 5_000_000_000
    private static let successDurationNanoseconds: UInt64 = 1_400_000_000
    private static let presentationDuration: TimeInterval = 0.05
    private static let dismissalDuration: TimeInterval = 0.05

    private var panel: NSPanel?
    private var hostingView: NSHostingView<AutomaticDictionaryCorrectionOverlayView>?
    private var session: AutomaticDictionaryTrainingSession?
    private var sessionCancellable: AnyCancellable?
    private var dismissTask: Task<Void, Never>?
    private var outcomeHandler: ((AutomaticDictionarySuggestionOutcome) -> Void)?
    private var generation: UInt64 = 0

    private init() {}

    var isPresented: Bool {
        self.panel?.isVisible == true
    }

    func show(
        candidate: AutomaticDictionaryCorrectionCandidate,
        onOutcome: @escaping (AutomaticDictionarySuggestionOutcome) -> Void
    ) {
        self.generation &+= 1
        let currentGeneration = self.generation
        self.dismissTask?.cancel()
        self.session?.cancel()
        self.outcomeHandler = onOutcome

        let session = AutomaticDictionaryTrainingSession(
            candidate: candidate
        )
        session.onInteraction = { [weak self] in
            self?.keepVisible()
        }
        session.onSuccess = { [weak self] in
            self?.reportOutcome(.accepted)
            self?.scheduleSuccessDismissal()
        }
        self.session = session

        let rootView = AutomaticDictionaryCorrectionOverlayView(
            session: session,
            displayDuration: Double(Self.displayDurationNanoseconds) / 1_000_000_000,
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        )

        if let hostingView = self.hostingView {
            hostingView.rootView = rootView
        } else {
            self.createPanel(rootView: rootView)
        }

        self.sessionCancellable = session.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.resizeAndPositionPanel(animated: true)
                }
            }

        guard let panel = self.panel else { return }
        self.resizeAndPositionPanel(animated: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.presentationDuration
            context.allowsImplicitAnimation = true
            panel.animator().alphaValue = 1
        }

        self.dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.displayDurationNanoseconds)
            guard !Task.isCancelled,
                  let self,
                  self.generation == currentGeneration,
                  self.session?.screen == .choice
            else {
                return
            }
            self.reportOutcome(.timedOut)
            self.hide()
        }
    }

    func hide() {
        self.generation &+= 1
        let hideGeneration = self.generation
        self.dismissTask?.cancel()
        self.dismissTask = nil
        self.session?.cancel()
        guard let panel, panel.isVisible else {
            self.clearSession()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.dismissalDuration
            context.allowsImplicitAnimation = true
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == hideGeneration else { return }
                self.panel?.orderOut(nil)
                self.panel?.alphaValue = 1
                self.clearSession()
            }
        }
    }

    func dismiss() {
        self.reportOutcome(.dismissed)
        self.hide()
    }

    private func keepVisible() {
        self.dismissTask?.cancel()
        self.dismissTask = nil
    }

    private func scheduleSuccessDismissal() {
        self.keepVisible()
        let successGeneration = self.generation
        self.dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.successDurationNanoseconds)
            guard !Task.isCancelled,
                  let self,
                  self.generation == successGeneration
            else {
                return
            }
            self.hide()
        }
    }

    private func clearSession() {
        self.sessionCancellable?.cancel()
        self.sessionCancellable = nil
        self.session = nil
        self.outcomeHandler = nil
    }

    private func reportOutcome(_ outcome: AutomaticDictionarySuggestionOutcome) {
        guard let outcomeHandler = self.outcomeHandler else { return }
        self.outcomeHandler = nil
        outcomeHandler(outcome)
    }

    private func createPanel(rootView: AutomaticDictionaryCorrectionOverlayView) {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        panel.contentView = hostingView

        self.panel = panel
        self.hostingView = hostingView
    }

    private func resizeAndPositionPanel(animated: Bool) {
        guard let panel, let hostingView,
              let screen = OverlayScreenResolver.screenForCurrentPointer() ?? NSScreen.main
        else {
            return
        }

        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        let size = NSSize(width: ceil(fittingSize.width), height: ceil(fittingSize.height))
        guard size.width > 0, size.height > 0 else { return }
        hostingView.frame = NSRect(origin: .zero, size: size)

        let visibleFrame = screen.visibleFrame
        let requestedY = visibleFrame.minY + CGFloat(SettingsStore.shared.overlayBottomOffset)
        let y = max(visibleFrame.minY + 10, min(requestedY, visibleFrame.maxY - size.height - 40))
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: y,
            width: size.width,
            height: size.height
        )

        guard animated, panel.isVisible else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }
}

private struct AutomaticDictionaryCorrectionOverlayView: View {
    @ObservedObject var session: AutomaticDictionaryTrainingSession
    @ObservedObject private var settings = SettingsStore.shared

    let displayDuration: TimeInterval
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDismissHovered = false
    @State private var progress: CGFloat = 1

    private var accent: Color { self.settings.accentColor }

    var body: some View {
        Group {
            switch self.session.screen {
            case .choice:
                self.choiceContent
            case .success:
                self.successContent
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 460)
        .background(self.overlayBackground)
        .overlay(alignment: .bottomLeading) {
            if self.session.screen == .choice {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Color.white.opacity(0.72))
                        .frame(width: proxy.size.width * self.progress, height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 3)
                .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.dark)
        .animation(self.reduceMotion ? nil : .easeOut(duration: 0.16), value: self.session.screen)
        .onAppear {
            self.startProgressAnimation()
        }
    }

    private var choiceContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            self.header(title: "Correction noticed")

            self.correctionPair

            Text("Save this correction to your dictionary.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)

            HStack(spacing: 8) {
                CorrectionOverlayActionButton(
                    title: "Add This Correction",
                    systemImage: "plus",
                    style: .accent,
                    accent: self.accent,
                    action: self.session.addOnlyCorrection
                )
            }
        }
        .transition(.opacity)
    }

    private var successContent: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(self.accent.opacity(0.18))
                    .frame(width: 38, height: 38)
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(self.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(self.session.successTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("“\(self.session.candidate.heardText)” will become “\(self.session.candidate.correctedText)”.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }

    private func header(title: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "mic.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.78))
                .frame(width: 24, height: 24)

            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))

            Spacer(minLength: 8)

            Button(action: self.onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(self.isDismissHovered ? 0.95 : 0.68))
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(self.isDismissHovered ? 0.13 : 0.06))
                    )
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .onHover { self.isDismissHovered = $0 }
            .help("Dismiss")
        }
    }

    private var correctionPair: some View {
        HStack(spacing: 8) {
            Text(self.session.candidate.heardText)
                .foregroundStyle(.white.opacity(0.78))

            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.42))

            Text(self.session.candidate.correctedText)
                .foregroundStyle(.white)
        }
        .font(.system(size: 16, weight: .semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func startProgressAnimation() {
        self.progress = 1
        guard !self.reduceMotion else { return }
        DispatchQueue.main.async {
            withAnimation(.linear(duration: self.displayDuration)) {
                self.progress = 0
            }
        }
    }

    private var overlayBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.black)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.15), .white.opacity(0.08)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
    }
}

private struct CorrectionOverlayActionButton: View {
    enum Style {
        case accent
        case secondary
    }

    let title: String
    let systemImage: String
    let style: Style
    let accent: Color
    var isEnabled = true
    var isReady = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var isGlowExpanded = false

    private var shouldPulse: Bool {
        self.isReady && self.isEnabled && !self.isHovered && !self.reduceMotion
    }

    var body: some View {
        Button(action: self.action) {
            Label(self.title, systemImage: self.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(self.isEnabled ? 0.94 : 0.42))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(self.background)
        }
        .buttonStyle(.plain)
        .disabled(!self.isEnabled)
        .onHover { self.isHovered = $0 }
        .onAppear { self.updateGlow() }
        .onChange(of: self.shouldPulse) { _, _ in
            self.updateGlow()
        }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(self.fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(self.borderColor, lineWidth: self.isReady ? 1.5 : 1)
            )
            .shadow(
                color: self.isReady ? self.accent.opacity(self.isGlowExpanded ? 0.34 : 0.14) : .clear,
                radius: self.isReady ? (self.isGlowExpanded ? 16 : 7) : 0,
                y: 3
            )
    }

    private var fillColor: Color {
        guard self.isEnabled else {
            return Color.white.opacity(0.045)
        }
        switch self.style {
        case .accent:
            return self.accent.opacity(self.isHovered ? 1 : 0.9)
        case .secondary:
            return Color.white.opacity(self.isHovered ? 0.1 : 0.045)
        }
    }

    private var borderColor: Color {
        guard self.isEnabled else {
            return Color.white.opacity(0.1)
        }
        if self.isReady {
            return self.accent.opacity(0.78)
        }
        switch self.style {
        case .accent:
            return Color.white.opacity(self.isEnabled ? 0.18 : 0.06)
        case .secondary:
            return Color.white.opacity(self.isHovered ? 0.28 : 0.16)
        }
    }

    private func updateGlow() {
        guard self.shouldPulse else {
            withAnimation(.easeOut(duration: 0.16)) {
                self.isGlowExpanded = false
            }
            return
        }

        self.isGlowExpanded = false
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
            self.isGlowExpanded = true
        }
    }
}
