//
//  WelcomeView.swift
//  VebeVoice
//
//  Welcome and setup guide view
//

import AppKit
import AVFoundation
import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var appServices: AppServices
    private var asr: ASRService {
        self.appServices.asr
    }

    @ObservedObject private var settings = SettingsStore.shared
    @Binding var selectedSidebarItem: SidebarItem?
    @Binding var playgroundUsed: Bool
    @State private var showSetupChecklist = false
    @State private var isHowToUseExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme

    let accessibilityEnabled: Bool
    let openAccessibilitySettings: () -> Void

    private var appDisplayName: String {
        Bundle.main.vibeAppDisplayName
    }

    private var isOnboarded: Bool {
        self.asr.isAsrReady || self.asr.modelsExistOnDisk
    }

    private var isReadyToDictate: Bool {
        self.isOnboarded && self.accessibilityEnabled && self.asr.micStatus == .authorized
    }

    private var heroTitle: String {
        if self.isReadyToDictate { return "You're all set" }
        return self.isOnboarded ? "Almost ready" : "Welcome to \(self.appDisplayName)"
    }

    private var heroSubtitle: String {
        if self.isReadyToDictate || !self.isOnboarded {
            return "Capture a quick thought or take your time. Your words become text in the app you’re using."
        }
        return "Finish the permission steps below, then press your shortcut anywhere to start dictating."
    }

    /// Premium welcome hero: a light-lavender gradient panel with a voice
    /// illustration (unDraw), giving the setup screen a polished first moment.
    /// The panel is intentionally light so the illustration reads correctly and
    /// pops as a bright accent within the dark app chrome.
    private var welcomeHero: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(self.heroTitle)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color(hex: "1e1040")!)
                    .fixedSize(horizontal: false, vertical: true)

                Text(self.heroSubtitle)
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(Color(hex: "5b4585")!)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Image("VoiceNotesHero")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 190, height: 128)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color(hex: "f3eeff")!, Color(hex: "e4d7ff")!],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color(hex: "cbb6f7")!.opacity(0.7), lineWidth: 1)
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    self.welcomeHero

                    DictationSessionStatus(asr: self.asr)

                    HStack(spacing: 12) {
                        Button { self.selectedSidebarItem = .testPlayground } label: {
                            Label("Open dictation workspace", systemImage: "text.bubble")
                        }
                        .vibeButton(.primary, size: .large)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 6) {
                            Text(self.settings.primaryDictationShortcutDisplayString)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(self.theme.palette.primaryText)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(self.theme.palette.elevatedCardBackground)
                                        .shadow(color: self.theme.palette.cardBorder.opacity(0.9), radius: 0, x: 0, y: 2)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(self.theme.palette.cardBorder, lineWidth: 1)
                                )
                                .help("Dictation shortcut")
                            Text(self.asr.activeProviderName)
                                .font(self.theme.typography.caption)
                                .foregroundStyle(self.theme.palette.secondaryText)
                        }
                    }
                    .padding(.vertical, 4)

                    if self.isReadyToDictate && self.playgroundUsed {
                        Button {
                            self.showSetupChecklist.toggle()
                        } label: {
                            HStack {
                                Label("Setup complete", systemImage: "checkmark.seal")
                                Spacer()
                                Text(self.showSetupChecklist ? "Hide checklist" : "View checklist")
                                Image(systemName: self.showSetupChecklist ? "chevron.up" : "chevron.down")
                            }
                            .font(self.theme.typography.captionStrong)
                            .padding(16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(self.theme.palette.secondaryText)
                    }

                    if self.showSetupChecklist || !self.isOnboarded || !self.accessibilityEnabled || self.asr.micStatus != .authorized || !self.playgroundUsed {
                        // Quick Setup Checklist
                        ThemedCard(style: .prominent) {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 10) {
                                    Label("Quick Setup", systemImage: "checkmark.circle.fill")
                                        .font(self.theme.typography.sectionTitle)
                                        .foregroundStyle(self.theme.palette.accent)

                                    Spacer()

                                    Button {
                                        self.settings.resetOnboardingProgress()
                                        self.playgroundUsed = false
                                    } label: {
                                        Label("Run Onboarding Again", systemImage: "arrow.counterclockwise")
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }

                                VStack(alignment: .leading, spacing: 8) {
                                    SetupStepView(
                                        step: 1,
                                        // Consider model step complete if ready OR downloaded (even if not loaded)
                                        title: (self.asr.isAsrReady || self.asr.modelsExistOnDisk) ? "Voice Model Ready" : "Download Voice Model",
                                        description: self.asr.isAsrReady
                                            ? "Speech recognition model is loaded and ready"
                                            : (
                                                self.asr.modelsExistOnDisk
                                                    ? "Model downloaded, will load when needed"
                                                    : "Download the AI model for offline voice transcription (~500MB)"
                                            ),
                                        status: (self.asr.isAsrReady || self.asr.modelsExistOnDisk) ? .completed : .pending,
                                        action: {
                                            self.selectedSidebarItem = .voiceEngine
                                        },
                                        actionButtonTitle: "Go to Voice Engine",
                                        showActionButton: !(self.asr.isAsrReady || self.asr.modelsExistOnDisk)
                                    )

                                    SetupStepView(
                                        step: 2,
                                        title: self.asr.micStatus == .authorized ? "Microphone Permission Granted" : "Grant Microphone Permission",
                                        description: self.asr.micStatus == .authorized
                                            ? "VebeVoice has access to your microphone"
                                            : "Allow VebeVoice to access your microphone for voice input",
                                        status: self.asr.micStatus == .authorized ? .completed : .pending,
                                        action: {
                                            if self.asr.micStatus == .notDetermined {
                                                self.asr.requestMicAccess()
                                            } else if self.asr.micStatus == .denied {
                                                self.asr.openSystemSettingsForMic()
                                            }
                                        },
                                        actionButtonTitle: self.asr.micStatus == .notDetermined ? "Grant Access" : "Open Settings",
                                        showActionButton: self.asr.micStatus != .authorized
                                    )

                                    SetupStepView(
                                        step: 3,
                                        title: self.accessibilityEnabled ? "Accessibility Access Enabled" : "Enable Accessibility Access",
                                        description: self.accessibilityEnabled
                                            ? "Accessibility permission granted for typing into apps"
                                            : "Turn on \(self.appDisplayName) in Privacy & Security → Accessibility",
                                        status: self.accessibilityEnabled ? .completed : .pending,
                                        action: {
                                            self.openAccessibilitySettings()
                                        },
                                        actionButtonTitle: "Open Settings",
                                        showActionButton: !self.accessibilityEnabled
                                    )

                                    SetupStepView(
                                        step: 4,
                                        title: self.playgroundUsed ? "Setup Tested Successfully" : "Test Your Setup",
                                        description: self.playgroundUsed
                                            ? "You've successfully tested voice transcription"
                                            : "Open Playground to test recording and transcription",
                                        status: self.playgroundUsed ? .completed : .pending,
                                        action: {
                                            self.selectedSidebarItem = .testPlayground
                                        },
                                        actionButtonTitle: "Open Playground",
                                        showActionButton: !self.playgroundUsed
                                    )
                                    .id("playground-step-\(self.playgroundUsed)")
                                }
                            }
                            .padding(14)
                        }

                    }

                    // Secondary guidance
                    ThemedCard(style: .subtle) {
                        VStack(alignment: .leading, spacing: 12) {
                            self.guideDisclosureRow(
                                title: "How to Use",
                                systemImage: "play.fill",
                                color: self.theme.palette.accent,
                                isExpanded: self.$isHowToUseExpanded
                            ) {
                                EmptyView()
                            } content: {
                                VStack(alignment: .leading, spacing: 10) {
                                    self.howToStep(number: 1, title: "Start Recording", description: "Press your hotkey (default: Right Option/Alt) or click the button")
                                    self.howToStep(number: 2, title: "Speak Clearly", description: "Speak naturally - works best in quiet environments")
                                    self.howToStep(number: 3, title: "Auto-Type Result", description: "Transcription is automatically typed into your focused app")
                                }
                            }
                        }
                        .padding(12)
                    }
                }
                .vibePageContentColumn()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            // CRITICAL FIX: Refresh microphone and model status immediately on appear
            // This prevents the Quick Setup from showing stale status before ASRService.initialize() runs
            Task { @MainActor in
                // Check microphone status without triggering the full initialize() delay
                self.asr.micStatus = AVCaptureDevice.authorizationStatus(for: .audio)

                // Check if models exist on disk (async for accurate detection with AppleSpeechAnalyzerProvider)
                await self.asr.checkIfModelsExistAsync()
            }
        }
    }

    // MARK: - Helper Views

    private func guideDisclosureRow<Accessories: View, Content: View>(
        title: String,
        systemImage: String,
        color: Color,
        isExpanded: Binding<Bool>,
        @ViewBuilder accessories: () -> Accessories,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(self.reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.85))
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                        .frame(width: 16)

                    Label(title, systemImage: systemImage)
                        .font(self.theme.typography.sectionTitle)
                        .foregroundStyle(color)

                    accessories()

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(isExpanded.wrappedValue ? "Expanded" : "Collapsed"))
            .accessibilityHint(Text("Activates to expand or collapse"))

            if isExpanded.wrappedValue {
                content()
                    .padding(.top, 8)
                    .padding(.leading, 26)
            }
        }
    }

    private func howToStep(number: Int, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(self.theme.palette.accent.opacity(0.15))
                    .frame(width: 28, height: 28)
                Text("\(number)")
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.theme.palette.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(self.theme.typography.bodyStrong)
                Text(description)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

}

struct OnboardingFlowView: View {
    @EnvironmentObject var appServices: AppServices
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var asr: ASRService {
        self.appServices.asr
    }

    @ObservedObject private var settings = SettingsStore.shared

    @Binding var currentStep: Int
    let accessibilityEnabled: Bool
    let accessibilitySetupInProgress: Bool
    let finishOnboarding: () -> Void
    let openAccessibilitySettings: () -> Void
    @Binding var activeShortcutRecordingTarget: ShortcutRecordingTarget?
    @Binding var shortcutRecordingMessage: String?
    let theme: AppTheme

    @State private var selectedLanguageID = SettingsStore.shared.onboardingSelectedLanguageID
    @State private var selectedModelRouteID: String?
    @State private var hoveredLanguageID: String?
    @State private var hoveredModelRouteID: String?
    @State private var hoveredModelActionButtonID: String?
    @State private var hoveredPermissionButtonID: String?
    @State private var hoveredFooterButton: OnboardingFooterButton?
    @State private var isShowingAllLanguages = false
    @State private var isShowingOtherModelRoutes = false
    @State private var preparingModelRouteID: String?
    @State private var uninstallingModelRouteID: String?
    @State private var modelPreparationTask: Task<Void, Never>?
    @State private var languageSearchText = ""
    @FocusState private var isLanguageSearchFocused: Bool
    @State private var hasPlayedLandingWelcomeSound = false
    @State private var landingGlowCenter = UnitPoint(x: 0.5, y: 0.18)
    @State private var lastLandingGlowLocation = CGPoint(x: -1000, y: -1000)
    private let landingGlowMovementThreshold: CGFloat = 24

    private enum OnboardingFooterButton {
        case back
        case skip
        case next
    }

    private enum OnboardingPillButtonTone {
        case primary
        case secondary
        case destructive
    }

    private struct OnboardingPillButtonConfiguration {
        let title: String
        let systemImage: String?
        let tone: OnboardingPillButtonTone
        let width: CGFloat?
        let height: CGFloat
        let fontSize: CGFloat
        let iconSize: CGFloat
        let isHovered: Bool
        let isEnabled: Bool
    }

    private enum Step: Int, CaseIterable {
        case landing = 0
        case language = 1
        case voiceModel = 2
        case permissions = 3
        case playground = 4

    }

    private var step: Step {
        Step(rawValue: self.currentStep) ?? .voiceModel
    }

    private var compactProgressValue: Double {
        Double(self.step.rawValue + 1) / Double(Step.allCases.count)
    }

    private var popularOnboardingLanguages: [VoiceEngineLanguage] {
        VoiceEngineLanguageCatalog.popularLanguages()
    }

    private var selectedOnboardingLanguage: VoiceEngineLanguage {
        VoiceEngineLanguageCatalog.language(id: self.selectedLanguageID)
            ?? VoiceEngineLanguageCatalog.language(id: "en")
            ?? VoiceEngineLanguage(id: "en", displayName: "English", aliases: [], isPopular: true)
    }

    private var searchedOnboardingLanguages: [VoiceEngineLanguage] {
        VoiceEngineLanguageCatalog.searchableLanguages(query: self.languageSearchText)
    }

    private var selectedLanguageRoutes: [VoiceEngineLanguageRoute] {
        VoiceEngineLanguageCatalog.routes(for: self.selectedOnboardingLanguage)
    }

    private var selectedOnboardingRoute: VoiceEngineLanguageRoute? {
        if let selectedModelRouteID,
           let selectedRoute = self.selectedLanguageRoutes.first(where: { $0.id == selectedModelRouteID })
        {
            return selectedRoute
        }

        if let selectedRoute = self.selectedLanguageRoutes.first(where: { self.isRouteSelectedInSettings($0) }) {
            return selectedRoute
        }

        return self.selectedLanguageRoutes.first
    }

    private var primaryDisplayedModelRoute: VoiceEngineLanguageRoute? {
        self.selectedLanguageRoutes.first
    }

    private var defaultDisplayedModelRoutes: [VoiceEngineLanguageRoute] {
        var routes: [VoiceEngineLanguageRoute] = []
        if let primaryDisplayedModelRoute {
            routes.append(primaryDisplayedModelRoute)
        }
        if let builtInRoute = self.defaultBuiltInModelRoute,
           !routes.contains(where: { $0.id == builtInRoute.id })
        {
            routes.append(builtInRoute)
        }
        return routes
    }

    private var defaultBuiltInModelRoute: VoiceEngineLanguageRoute? {
        guard self.selectedOnboardingLanguage.id == "en" else {
            return nil
        }

        return self.selectedLanguageRoutes.first { route in
            switch route.model {
            case .appleSpeech, .appleSpeechAnalyzer:
                return true
            default:
                return false
            }
        }
    }

    private var otherModelRoutes: [VoiceEngineLanguageRoute] {
        let defaultRouteIDs = Set(self.defaultDisplayedModelRoutes.map(\.id))
        return self.selectedLanguageRoutes.filter { !defaultRouteIDs.contains($0.id) }
    }

    private var recommendedModelReasonText: String {
        "Recommended for \(self.selectedOnboardingLanguage.displayName). You can see more options if needed."
    }

    private var isVoiceModelReady: Bool {
        guard let route = self.selectedOnboardingRoute else {
            return false
        }
        return self.isOnboardingRouteReady(route)
    }

    private var isModelPreparationInProgress: Bool {
        guard self.step == .voiceModel else {
            return false
        }
        return self.preparingModelRouteID != nil
            || self.asr.hasActiveModelPreparation
            || self.asr.isCancellingModelPreparation
            || self.asr.isDownloadingModel
            || (self.asr.isLoadingModel && !self.asr.isAsrReady)
    }

    private var isMicrophoneReady: Bool {
        self.asr.micStatus == .authorized
    }

    private var isAccessibilityReady: Bool {
        self.accessibilityEnabled
    }

    private var isPermissionsReady: Bool {
        self.isMicrophoneReady && self.isAccessibilityReady
    }

    private var isPlaygroundReady: Bool {
        self.settings.onboardingPlaygroundValidated || self.settings.onboardingPlaygroundSkipped
    }

    private var onboardingShortcutDisplay: String {
        let display = self.settings.primaryDictationShortcutDisplayString.trimmingCharacters(in: .whitespacesAndNewlines)
        return display.isEmpty ? "your shortcut" : display
    }

    private var isRecordingAnyShortcut: Bool {
        self.activeShortcutRecordingTarget != nil
    }

    private var isRecordingPrimaryShortcut: Bool {
        self.activeShortcutRecordingTarget?.isPrimaryDictation == true
    }

    private var canContinue: Bool {
        guard !self.isModelPreparationInProgress else {
            return false
        }

        switch self.step {
        case .landing:
            return true
        case .language:
            return !self.selectedLanguageRoutes.isEmpty
        case .voiceModel:
            return self.isVoiceModelReady
        case .permissions:
            return self.isPermissionsReady
        case .playground:
            return self.isPlaygroundReady && !self.asr.isRunning && !self.isRecordingAnyShortcut
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            self.stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .background {
            ZStack {
                self.theme.palette.windowBackground
                    .opacity(0.98)
                    .ignoresSafeArea()

                Rectangle()
                    .fill(self.theme.materials.window)
                    .opacity(0.75)
                    .ignoresSafeArea()
            }
        }
        .onAppear {
            self.syncOnboardingSelectionFromSettings()
            self.playLandingWelcomeSoundIfNeeded()
            Task { @MainActor in
                self.asr.micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                await self.asr.checkIfModelsExistAsync()
            }
        }
        .onChange(of: self.currentStep) { _, _ in
            if self.step != .voiceModel {
                self.cancelOnboardingModelPreparation()
            }
            self.playLandingWelcomeSoundIfNeeded()
        }
        .onDisappear {
            self.cancelOnboardingModelPreparation()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            self.syncOnboardingSelectionFromSettings()
            self.asr.micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch self.step {
        case .landing:
            self.landingStep
        case .language:
            self.languageStep
        case .voiceModel:
            self.voiceModelStep
        case .permissions:
            self.permissionsStep
        case .playground:
            self.playgroundStep
        }
    }

    private var landingStep: some View {
        GeometryReader { proxy in
            let landing = self.theme.metrics.onboardingSurface.landing

            ZStack {
                VStack(alignment: .center, spacing: self.theme.metrics.onboardingSurface.landing.sectionSpacing) {
                    VibeOnboardingLandingHero(
                        eyebrow: "",
                        title: "Just speak.",
                        accentTitle: "We'll handle the rest.",
                        firstDetail: "Accurate. Fast. Private. Free.",
                        secondDetail: "Built for creators, thinkers, and builders."
                    ) {
                        VibeOnboardingLandingPrimaryButton(title: "Next") {
                            self.goNext()
                        }
                        .frame(
                            width: VibeOnboardingLandingPrimaryButton.size.width,
                            height: VibeOnboardingLandingPrimaryButton.size.height
                        )
                    }
                }
                .frame(width: landing.contentWidth, alignment: .center)
                .frame(maxWidth: .infinity)
                .frame(minHeight: proxy.size.height, alignment: .center)
                .offset(y: -78)
                .padding(.horizontal, 24)
                .padding(.vertical, 24)

                VibeOnboardingLandingHoverTracker(
                    onMove: { location, size in
                        self.updateLandingGlow(location: location, in: size)
                    },
                    onExit: {
                        self.resetLandingGlow()
                    }
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .accessibilityHidden(true)
                .zIndex(-1)
            }
            .background {
                VibeOnboardingLandingBackdrop(glowCenter: self.landingGlowCenter)
            }
        }
    }

    private func updateLandingGlow(location: CGPoint, in size: CGSize) {
        guard !self.reduceMotion else { return }
        guard location.x.isFinite, location.y.isFinite, size.width > 0, size.height > 0 else { return }

        let dx = location.x - self.lastLandingGlowLocation.x
        let dy = location.y - self.lastLandingGlowLocation.y
        guard (dx * dx) + (dy * dy) > (self.landingGlowMovementThreshold * self.landingGlowMovementThreshold) else { return }

        self.lastLandingGlowLocation = location
        let normalizedX = min(max(location.x / size.width, 0), 1)
        let normalizedY = min(max(location.y / size.height, 0), 1)

        withAnimation(.easeOut(duration: 0.22)) {
            self.landingGlowCenter = UnitPoint(x: normalizedX, y: normalizedY)
        }
    }

    private func resetLandingGlow() {
        guard !self.reduceMotion else { return }
        self.lastLandingGlowLocation = CGPoint(x: -1000, y: -1000)

        withAnimation(.easeOut(duration: 0.35)) {
            self.landingGlowCenter = UnitPoint(x: 0.5, y: 0.18)
        }
    }

    private func playLandingWelcomeSoundIfNeeded() {
        guard self.step == .landing, !self.hasPlayedLandingWelcomeSound else { return }
        self.hasPlayedLandingWelcomeSound = true
        OnboardingSoundPlayer.shared.playWelcomeSound()
    }

    private var languageStep: some View {
        GeometryReader { proxy in
            ZStack {
                VibeOnboardingLandingBackdrop(glowCenter: self.landingGlowCenter)

                VStack(spacing: 0) {
                    VibeOnboardingCompactProgress(value: self.compactProgressValue)
                        .padding(.top, 28)

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            VibeOnboardingCompactAppIconMark(size: 66)
                                .padding(.bottom, 22)

                            Text("What language will\nyou speak most?")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .lineSpacing(4)
                                .padding(.bottom, 18)

                            Text("We'll show the best voice engines for it.")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.62))
                                .padding(.bottom, 26)

                            LazyVGrid(
                                columns: [
                                    GridItem(.fixed(166), spacing: 16),
                                    GridItem(.fixed(166), spacing: 16),
                                    GridItem(.fixed(166), spacing: 16),
                                ],
                                spacing: 16
                            ) {
                                ForEach(self.popularOnboardingLanguages) { language in
                                    self.languageChoiceCard(for: language)
                                }

                                self.otherLanguageCard
                            }
                            .frame(width: 530)

                            if self.isShowingAllLanguages {
                                self.allLanguagesPicker
                                    .padding(.top, 18)
                            }

                            Text("You can change this later in Voice Engine settings.")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.44))
                                .padding(.top, 18)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 30)
                        .padding(.bottom, 12)
                    }

                    self.cinematicFooter(
                        continueTitle: "Continue",
                        canContinue: self.canContinue
                    ) {
                        self.handlePrimaryAction()
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)

                VibeOnboardingLandingHoverTracker(
                    onMove: { location, size in
                        self.updateLandingGlow(location: location, in: size)
                    },
                    onExit: {
                        self.resetLandingGlow()
                    }
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .accessibilityHidden(true)
            }
        }
    }

    private func languageChoiceCard(for language: VoiceEngineLanguage) -> some View {
        let isSelected = self.selectedLanguageID == language.id
        let isHovered = self.hoveredLanguageID == language.id
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        let cardFillOpacity = isSelected
            ? (isHovered ? 0.15 : 0.075)
            : (isHovered ? 0.10 : 0.04)
        let borderColor = isSelected
            ? VibeOnboardingLandingColors.blue.opacity(isHovered ? 1 : 0.92)
            : (isHovered ? VibeOnboardingLandingColors.blue.opacity(0.58) : Color.white.opacity(0.10))
        let borderWidth: CGFloat = isSelected
            ? (isHovered ? 1.8 : 1.4)
            : (isHovered ? 1.2 : 1)
        let shadowColor = isSelected
            ? VibeOnboardingLandingColors.blue.opacity(isHovered ? 0.36 : 0.18)
            : VibeOnboardingLandingColors.blue.opacity(isHovered ? 0.18 : 0)
        let shadowRadius: CGFloat = isSelected
            ? (isHovered ? 24 : 18)
            : (isHovered ? 20 : 14)

        return Button {
            self.selectOnboardingLanguage(language)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "globe")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isSelected ? VibeOnboardingLandingColors.blue : Color.white.opacity(0.72))
                    .frame(width: 22)

                Text(language.popularDisplayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(VibeOnboardingLandingColors.blue)
                }
            }
            .padding(.horizontal, 15)
            .frame(width: 166, height: 58)
            .background(
                shape
                    .fill(Color.white.opacity(cardFillOpacity))
                    .overlay(
                        shape.stroke(
                            borderColor,
                            lineWidth: borderWidth
                        )
                    )
            )
            .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: 0)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered in
            if isHovered {
                self.setHoveredLanguage(language.id)
            } else if self.hoveredLanguageID == language.id {
                self.setHoveredLanguage(nil)
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    self.selectOnboardingLanguage(language)
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(language.displayName)
        .accessibilityValue(isSelected ? "Selected" : "")
    }

    private var otherLanguageCard: some View {
        let isSelected = !self.selectedOnboardingLanguage.isPopular
        let isHovered = self.hoveredLanguageID == "other"
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        let fillOpacity = isSelected
            ? (isHovered ? 0.15 : 0.075)
            : (isHovered ? 0.10 : 0.04)
        let borderColor = isSelected
            ? VibeOnboardingLandingColors.blue.opacity(isHovered ? 1 : 0.92)
            : (isHovered ? VibeOnboardingLandingColors.blue.opacity(0.58) : Color.white.opacity(self.isShowingAllLanguages ? 0.16 : 0.10))
        let shadowColor = isSelected
            ? VibeOnboardingLandingColors.blue.opacity(isHovered ? 0.36 : 0.18)
            : VibeOnboardingLandingColors.blue.opacity(isHovered ? 0.18 : 0)

        return Button {
            self.toggleAllLanguagesPicker()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(isSelected ? VibeOnboardingLandingColors.blue : Color.white.opacity(self.isShowingAllLanguages ? 0.78 : 0.72))
                    .frame(width: 22)

                Text(isSelected ? self.selectedOnboardingLanguage.displayName : "Other")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)

                Spacer(minLength: 0)

                Image(systemName: self.isShowingAllLanguages ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.46))
            }
            .padding(.horizontal, 15)
            .frame(width: 166, height: 58)
            .background(
                shape
                    .fill(Color.white.opacity(fillOpacity))
                    .overlay(
                        shape.stroke(
                            borderColor,
                            lineWidth: isSelected ? 1.4 : 1
                        )
                    )
            )
            .shadow(color: shadowColor, radius: isSelected ? (isHovered ? 24 : 18) : 20, x: 0, y: 0)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered in
            self.setHoveredLanguage(isHovered ? "other" : nil)
        }
        .accessibilityLabel("Other languages")
        .accessibilityValue(self.isShowingAllLanguages ? "Expanded" : "Collapsed")
    }

    private var allLanguagesPicker: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.48))

                TextField(
                    "",
                    text: self.$languageSearchText,
                    prompt: Text("Search supported languages")
                        .foregroundStyle(Color.white.opacity(0.42))
                )
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .focused(self.$isLanguageSearchFocused)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .frame(width: 530, height: 38)
            .contentShape(Rectangle())
            .onTapGesture {
                self.isLanguageSearchFocused = true
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    )
            )

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 6) {
                    ForEach(self.searchedOnboardingLanguages) { language in
                        self.languageSearchRow(for: language)
                    }
                }
                .padding(8)
            }
            .frame(width: 530, height: 156)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.045))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
        }
    }

    private func languageSearchRow(for language: VoiceEngineLanguage) -> some View {
        let isSelected = self.selectedLanguageID == language.id

        return Button {
            self.selectOnboardingLanguage(language)
        } label: {
            HStack(spacing: 10) {
                Text(language.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(VibeOnboardingLandingColors.blue)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? VibeOnboardingLandingColors.blue.opacity(0.14) : Color.white.opacity(0.045))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private func cinematicFooter(
        continueTitle: String,
        canContinue: Bool,
        continueAction: @escaping () -> Void,
        skipTitle: String? = nil,
        canSkip: Bool = false,
        skipAction: (() -> Void)? = nil
    ) -> some View {
        let canNavigateBack = !self.isModelPreparationInProgress && !self.asr.isRunning && !self.isRecordingAnyShortcut

        return HStack {
            self.cinematicFooterButton(
                title: "Back",
                kind: .back,
                isEnabled: canNavigateBack
            ) {
                self.goBack()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            if let skipTitle, let skipAction {
                self.cinematicFooterButton(
                    title: skipTitle,
                    kind: .skip,
                    isEnabled: canSkip
                ) {
                    skipAction()
                }
            }

            self.cinematicFooterButton(
                title: continueTitle,
                kind: .next,
                isEnabled: canContinue
            ) {
                continueAction()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 30)
        .padding(.bottom, 24)
    }

    private func cinematicFooterButton(
        title: String,
        kind: OnboardingFooterButton,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isPrimary = kind == .next
        let isHovered = self.hoveredFooterButton == kind && isEnabled

        return self.onboardingPillButton(
            configuration: OnboardingPillButtonConfiguration(
                title: title,
                systemImage: nil,
                tone: isPrimary ? .primary : .secondary,
                width: 132,
                height: 48,
                fontSize: 16,
                iconSize: 14,
                isHovered: isHovered,
                isEnabled: isEnabled
            ),
            action: action
        ) { isHovered in
            self.setHoveredFooterButton(isHovered ? kind : nil)
        }
        .accessibilityLabel(title)
    }

    private func setHoveredFooterButton(_ button: OnboardingFooterButton?) {
        guard self.hoveredFooterButton != button else { return }
        if self.reduceMotion {
            self.hoveredFooterButton = button
        } else {
            withAnimation(.easeOut(duration: 0.14)) {
                self.hoveredFooterButton = button
            }
        }
    }

    private func setHoveredLanguage(_ languageID: String?) {
        guard self.hoveredLanguageID != languageID else { return }
        if self.reduceMotion {
            self.hoveredLanguageID = languageID
        } else {
            withAnimation(.easeOut(duration: 0.14)) {
                self.hoveredLanguageID = languageID
            }
        }
    }

    private func toggleAllLanguagesPicker() {
        if self.isShowingAllLanguages {
            self.isShowingAllLanguages = false
            self.isLanguageSearchFocused = false
            self.languageSearchText = ""
        } else {
            self.isShowingAllLanguages = true
            self.isLanguageSearchFocused = true
        }
    }

    private func selectOnboardingLanguage(_ language: VoiceEngineLanguage) {
        guard self.selectedLanguageID != language.id else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            self.selectedLanguageID = language.id
            self.settings.onboardingSelectedLanguageID = language.id
            self.selectedModelRouteID = VoiceEngineLanguageCatalog.routes(for: language).first?.id
            self.isShowingOtherModelRoutes = false
            self.isLanguageSearchFocused = false
            if language.isPopular {
                self.isShowingAllLanguages = false
                self.languageSearchText = ""
            }
            self.resetTryoutValidationForSetupChange()
        }
    }

    private func syncOnboardingSelectionFromSettings() {
        let allRoutes = VoiceEngineLanguageCatalog.allLanguages()
            .flatMap { VoiceEngineLanguageCatalog.routes(for: $0) }

        let storedLanguageID = self.settings.onboardingSelectedLanguageID
        let storedLanguageRoutes = VoiceEngineLanguageCatalog.routes(forLanguageID: storedLanguageID)
        let route = storedLanguageRoutes.first { route in
            self.isRouteModelAndLanguageSettingsSelected(route)
        } ?? storedLanguageRoutes.first ?? allRoutes.first { route in
            self.isRouteModelAndLanguageSettingsSelected(route)
        }

        guard let route else {
            if self.selectedModelRouteID == nil {
                self.selectedModelRouteID = self.selectedLanguageRoutes.first?.id
            }
            return
        }

        guard self.selectedLanguageID != route.language.id || self.selectedModelRouteID != route.id else {
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            self.selectedLanguageID = route.language.id
            self.selectedModelRouteID = route.id
            self.isShowingOtherModelRoutes = false
            self.languageSearchText = ""
            self.isLanguageSearchFocused = false
        }
    }

    private var voiceModelStep: some View {
        GeometryReader { proxy in
            ZStack {
                VibeOnboardingLandingBackdrop(glowCenter: self.landingGlowCenter)

                VStack(spacing: 0) {
                    VibeOnboardingCompactProgress(value: self.compactProgressValue)
                        .padding(.top, 28)

                    ScrollView(.vertical, showsIndicators: self.isShowingOtherModelRoutes) {
                        VStack(spacing: 0) {
                            VibeOnboardingCompactAppIconMark(size: 66)
                                .padding(.bottom, 22)

                            Text("Choose your\nvoice engine")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, 16)

                            Text(self.recommendedModelReasonText)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.62))
                                .multilineTextAlignment(.center)
                                .padding(.bottom, 14)

                            Text(self.selectedOnboardingLanguage.displayName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(VibeOnboardingLandingColors.blue)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(VibeOnboardingLandingColors.blue.opacity(0.12))
                                        .overlay(Capsule().stroke(VibeOnboardingLandingColors.blue.opacity(0.24), lineWidth: 1))
                                )
                                .padding(.bottom, 18)

                            VStack(spacing: 10) {
                                let defaultRoutes = self.defaultDisplayedModelRoutes
                                if defaultRoutes.count == 1, let route = defaultRoutes.first {
                                    self.onboardingRouteCard(for: route)
                                } else if !defaultRoutes.isEmpty {
                                    HStack(spacing: 16) {
                                        ForEach(defaultRoutes) { route in
                                            self.onboardingRouteCard(for: route)
                                        }
                                    }
                                }

                                if !self.otherModelRoutes.isEmpty {
                                    self.otherModelRoutesToggleButton
                                }

                                if self.isShowingOtherModelRoutes {
                                    LazyVGrid(
                                        columns: [
                                            GridItem(.fixed(292), spacing: 16, alignment: .top),
                                            GridItem(.fixed(292), spacing: 16, alignment: .top),
                                        ],
                                        spacing: 16
                                    ) {
                                        ForEach(self.otherModelRoutes) { route in
                                            self.onboardingRouteCard(for: route, enablesHover: false)
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 2)
                            .transaction { transaction in
                                transaction.animation = nil
                            }
                            .frame(width: 608)

                            if self.isModelPreparationInProgress {
                                Label("Initial preparation can take a while to get your Mac ready for near-instant transcription.", systemImage: "clock.arrow.circlepath")
                                    .font(self.theme.typography.captionStrong)
                                    .foregroundStyle(Color.white.opacity(0.58))
                                    .labelStyle(.titleAndIcon)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.86)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule()
                                            .fill(Color.white.opacity(0.06))
                                            .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
                                    )
                                    .padding(.top, 14)
                            }

                            Text("You can switch models later in Voice Engine settings.")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.44))
                                .padding(.top, self.isModelPreparationInProgress ? 8 : 18)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 30)
                        .padding(.bottom, 12)
                    }

                    self.cinematicFooter(
                        continueTitle: "Continue",
                        canContinue: self.canContinue
                    ) {
                        self.handlePrimaryAction()
                    }
                }

                VibeOnboardingLandingHoverTracker(
                    onMove: { location, size in
                        self.updateLandingGlow(location: location, in: size)
                    },
                    onExit: {
                        self.resetLandingGlow()
                    }
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .accessibilityHidden(true)
            }
        }
    }

    private var permissionsStep: some View {
        GeometryReader { proxy in
            ZStack {
                VibeOnboardingLandingBackdrop(glowCenter: self.landingGlowCenter)

                VStack(spacing: 0) {
                    VibeOnboardingCompactProgress(value: self.compactProgressValue)
                        .padding(.top, 28)

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            VibeOnboardingCompactAppIconMark(size: 66)
                                .padding(.bottom, 22)

                            Text("Let VebeVoice\nlisten and type")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .lineSpacing(4)
                                .padding(.bottom, 16)

                            Text("Two quick permissions make dictation work anywhere.")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.62))
                                .padding(.bottom, 28)

                            VStack(spacing: 14) {
                                self.permissionRow(
                                    stepNumber: 1,
                                    title: self.isMicrophoneReady ? "Microphone is ready" : "Allow microphone",
                                    subtitle: self.isMicrophoneReady
                                        ? "VebeVoice can hear your dictation."
                                        : "macOS will ask once. Click Allow to start dictating.",
                                    systemImage: "mic.fill",
                                    isReady: self.isMicrophoneReady,
                                    actionTitle: self.microphoneActionButtonTitle
                                ) {
                                    self.handleMicrophoneAction()
                                }

                                self.permissionRow(
                                    stepNumber: 2,
                                    title: self.accessibilityPermissionTitle,
                                    subtitle: self.accessibilityPermissionSubtitle,
                                    systemImage: "keyboard.fill",
                                    isReady: self.isAccessibilityReady,
                                    statusTitle: self.accessibilityPermissionStatusTitle,
                                    actionTitle: self.accessibilityPermissionActionTitle
                                ) {
                                    self.openAccessibilitySettings()
                                }

                                if !self.isAccessibilityReady {
                                    Text("Already enabled it? VebeVoice will update when macOS confirms access.")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color.white.opacity(0.42))
                                        .padding(.top, 2)
                                }
                            }
                            .frame(width: 560)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 34)
                        .padding(.bottom, 12)
                    }

                    self.cinematicFooter(
                        continueTitle: "Continue",
                        canContinue: self.canContinue
                    ) {
                        self.handlePrimaryAction()
                    }
                }

                VibeOnboardingLandingHoverTracker(
                    onMove: { location, size in
                        self.updateLandingGlow(location: location, in: size)
                    },
                    onExit: {
                        self.resetLandingGlow()
                    }
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .accessibilityHidden(true)
            }
        }
    }

    private var playgroundStep: some View {
        GeometryReader { proxy in
            ZStack {
                VibeOnboardingLandingBackdrop(glowCenter: self.landingGlowCenter)

                VStack(spacing: 0) {
                    VibeOnboardingCompactProgress(value: self.compactProgressValue)
                        .padding(.top, 28)

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            VibeOnboardingCompactAppIconMark(size: 66)
                                .padding(.bottom, 22)

                            Text("VebeVoice is ready.")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.74)
                                .padding(.horizontal, 32)
                                .padding(.bottom, 14)

                            Text("Now let's try it out.")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.62))
                                .padding(.bottom, 28)

                            OnboardingTryoutStepView(
                                finalText: Binding(
                                    get: { self.asr.finalText },
                                    set: { self.asr.finalText = $0 }
                                ),
                                language: self.selectedOnboardingLanguage,
                                shortcutDisplay: self.onboardingShortcutDisplay,
                                isReady: self.isPlaygroundReady,
                                isRunning: self.asr.isRunning,
                                isRecordingShortcut: self.isRecordingPrimaryShortcut,
                                shortcutRecordingMessage: self.isRecordingPrimaryShortcut ? self.shortcutRecordingMessage : nil,
                                onToggleShortcut: self.togglePrimaryShortcutRecording
                            )
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 34)
                        .padding(.bottom, 12)
                    }

                    self.cinematicFooter(
                        continueTitle: "Continue",
                        canContinue: self.canContinue,
                        continueAction: {
                            self.handlePrimaryAction()
                        },
                        skipTitle: "Skip",
                        canSkip: !self.asr.isRunning && !self.isRecordingAnyShortcut,
                        skipAction: {
                            self.settings.onboardingPlaygroundSkipped = true
                            self.finishOnboarding()
                        }
                    )
                }
                .frame(width: proxy.size.width, height: proxy.size.height)

                VibeOnboardingLandingHoverTracker(
                    onMove: { location, size in
                        self.updateLandingGlow(location: location, in: size)
                    },
                    onExit: {
                        self.resetLandingGlow()
                    }
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .accessibilityHidden(true)
            }
        }
    }

    private var microphoneActionButtonTitle: String {
        switch self.asr.micStatus {
        case .notDetermined:
            return "Allow"
        case .denied, .restricted:
            return "Open Settings"
        default:
            return "Allow"
        }
    }

    private var accessibilityPermissionTitle: String {
        if self.isAccessibilityReady {
            return "Typing access is ready"
        }
        return self.accessibilitySetupInProgress ? "Finish Accessibility Access" : "Enable Accessibility Access"
    }

    private var accessibilityPermissionSubtitle: String {
        if self.isAccessibilityReady {
            return "\(self.appDisplayName) can place text into the app you're using."
        }
        if self.accessibilitySetupInProgress {
            return "Use the floating guide to drag \(self.appDisplayName) into the Accessibility apps list."
        }
        return "Open Settings, then use the floating guide to add \(self.appDisplayName)."
    }

    private var appDisplayName: String {
        Bundle.main.vibeAppDisplayName
    }

    private var accessibilityPermissionStatusTitle: String {
        if self.isAccessibilityReady {
            return "Ready"
        }
        return self.accessibilitySetupInProgress ? "In Settings" : "Needed"
    }

    private var accessibilityPermissionActionTitle: String {
        self.accessibilitySetupInProgress ? "Show Guide" : "Open Settings"
    }

    private var otherModelRoutesToggleButton: some View {
        Button {
            self.toggleOtherModelRoutes()
        } label: {
            HStack(spacing: 6) {
                Text(self.isShowingOtherModelRoutes ? "Hide other models" : "Show other models")

                Image(systemName: self.isShowingOtherModelRoutes ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.62))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.025))
                    .overlay(Capsule().stroke(Color.white.opacity(0.07), lineWidth: 1))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(self.isShowingOtherModelRoutes ? "Hide other models" : "Show other models")
    }

    private func toggleOtherModelRoutes() {
        self.isShowingOtherModelRoutes.toggle()
    }

    private func isOnboardingRouteReady(_ route: VoiceEngineLanguageRoute) -> Bool {
        self.isRouteSelectedInSettings(route) && self.asr.isAsrReady
    }

    private func isOnboardingModelBundledOrInstalled(_ model: SettingsStore.SpeechModel) -> Bool {
        model.isInstalled
    }

    private func onboardingModelActionButtonTitle(isPreparing: Bool, isDownloaded: Bool, isReady: Bool) -> String {
        if isPreparing {
            return self.asr.isLoadingModel ? "Loading..." : "Downloading..."
        }
        if isReady {
            return "Active now"
        }
        if isDownloaded {
            return "Activate"
        }
        return "Download & Activate"
    }

    private func prepareOnboardingRoute(_ route: VoiceEngineLanguageRoute) {
        guard !self.asr.isRunning, !self.isModelPreparationInProgress, self.uninstallingModelRouteID == nil else { return }

        self.modelPreparationTask?.cancel()
        self.preparingModelRouteID = route.id
        self.selectOnboardingRoute(route)

        self.modelPreparationTask = Task { @MainActor in
            defer {
                self.preparingModelRouteID = nil
                self.modelPreparationTask = nil
            }

            do {
                try await self.asr.ensureAsrReady()
            } catch is CancellationError {
                DebugLogger.shared.info("Cancelled onboarding voice model setup for \(route.model.displayName)", source: "OnboardingFlowView")
            } catch {
                DebugLogger.shared.error("Failed to prepare onboarding voice model \(route.model.displayName): \(error)", source: "OnboardingFlowView")
                // Surface the failure in the UI instead of only logging it, so the user
                // isn't stuck at a disabled button. The shared ContentView alert (bound to
                // asr.showError) presents this during onboarding.
                self.asr.errorTitle = "Voice Model Setup Failed"
                self.asr.errorMessage = error.localizedDescription
                self.asr.showError = true
            }
            guard !Task.isCancelled else { return }
            await self.asr.checkIfModelsExistAsync()
        }
    }

    private func cancelOnboardingModelPreparation() {
        self.modelPreparationTask?.cancel()
        self.asr.cancelModelPreparation()
    }

    private func uninstallOnboardingRoute(_ route: VoiceEngineLanguageRoute) {
        guard !self.asr.isRunning, !self.isModelPreparationInProgress, self.uninstallingModelRouteID == nil else { return }

        self.uninstallingModelRouteID = route.id

        Task { @MainActor in
            defer {
                self.uninstallingModelRouteID = nil
            }

            do {
                try await self.asr.clearModelCache(for: route.model)
                await self.asr.checkIfModelsExistAsync()
            } catch {
                DebugLogger.shared.error("Failed to delete onboarding voice model \(route.model.displayName): \(error)", source: "OnboardingFlowView")
                self.asr.errorTitle = "Model Delete Failed"
                self.asr.errorMessage = error.localizedDescription
                self.asr.showError = true
            }
        }
    }

    private func onboardingRouteCard(
        for route: VoiceEngineLanguageRoute,
        enablesHover: Bool = true
    ) -> some View {
        let model = route.model
        let isSelected = self.isOnboardingRouteSelected(route)
        let isHovered = enablesHover && self.hoveredModelRouteID == route.id
        let isRouteActiveInSettings = self.isRouteSelectedInSettings(route)
        let isDownloaded = self.isOnboardingModelBundledOrInstalled(model) || (isRouteActiveInSettings && (self.asr.isAsrReady || self.asr.modelsExistOnDisk))
        let isPreparing = self.preparingModelRouteID == route.id || (isRouteActiveInSettings && (self.asr.isDownloadingModel || (self.asr.isLoadingModel && !self.asr.isAsrReady)))
        let isReady = self.isOnboardingRouteReady(route)
        let isUninstalling = self.uninstallingModelRouteID == route.id
        let areModelActionsBlocked = self.asr.isRunning || self.uninstallingModelRouteID != nil || self.preparingModelRouteID != nil || isPreparing || self.isModelPreparationInProgress
        let isBuiltInAppleModel = model == .appleSpeech || model == .appleSpeechAnalyzer
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let cardFill = isHovered
            ? AppTheme.VibeBrand.elev
            : AppTheme.VibeBrand.card

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Text(self.onboardingModelTitle(for: model))
                    .font(self.theme.typography.sectionTitle)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Image(systemName: "info.circle")
                    .font(self.theme.typography.sectionTitle)
                    .foregroundStyle(Color.white.opacity(0.58))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
                    .help(self.onboardingModelTooltip(for: route))
                    .accessibilityLabel(self.onboardingModelTooltip(for: route))
            }
            .frame(height: 38, alignment: .top)

            self.onboardingModelMetadataRow(badgeText: route.badgeText)

            self.onboardingModelFeaturePanel(for: model)

            Spacer(minLength: 0)

            Divider()
                .overlay(Color.white.opacity(0.10))

            HStack(spacing: 10) {
                Image(systemName: "internaldrive")
                    .font(self.theme.typography.sectionTitle)
                    .foregroundStyle(Color.white.opacity(0.62))
                    .frame(width: 22)

                Text("Download size")
                    .font(self.theme.typography.bodySmallStrong)
                    .foregroundStyle(Color.white.opacity(0.62))

                Spacer()

                Text(model.downloadSize)
                    .font(self.theme.typography.bodySmallStrong)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.80)
            }

            if isPreparing || isUninstalling {
                HStack(spacing: 8) {
                    self.onboardingModelPreparationStatus(isUninstalling: isUninstalling)

                    if isPreparing {
                        self.onboardingModelActionButton(
                            id: "\(route.id)-cancel",
                            title: self.asr.isCancellingModelPreparation ? "Cancelling…" : "Cancel",
                            systemImage: "xmark",
                            tone: .secondary,
                            width: 104,
                            isDisabled: self.asr.isCancellingModelPreparation
                        ) {
                            self.cancelOnboardingModelPreparation()
                        }
                    }
                }
                .frame(height: 42, alignment: .center)
            } else if isDownloaded, isBuiltInAppleModel {
                self.onboardingModelActionButton(
                    id: "\(route.id)-activate",
                    title: self.onboardingModelActionButtonTitle(isPreparing: false, isDownloaded: true, isReady: isReady),
                    systemImage: isReady ? "checkmark" : "bolt.fill",
                    tone: .primary,
                    width: nil,
                    isDisabled: areModelActionsBlocked || isReady
                ) {
                    self.prepareOnboardingRoute(route)
                }
            } else if isDownloaded {
                HStack(spacing: 8) {
                    self.onboardingModelActionButton(
                        id: "\(route.id)-activate",
                        title: self.onboardingModelActionButtonTitle(isPreparing: false, isDownloaded: true, isReady: isReady),
                        systemImage: isReady ? "checkmark" : "bolt.fill",
                        tone: .primary,
                        width: 124,
                        isDisabled: areModelActionsBlocked || isReady
                    ) {
                        self.prepareOnboardingRoute(route)
                    }

                    self.onboardingModelActionButton(
                        id: "\(route.id)-uninstall",
                        title: "Delete",
                        systemImage: "trash",
                        tone: .destructive,
                        width: 124,
                        isDisabled: areModelActionsBlocked
                    ) {
                        self.uninstallOnboardingRoute(route)
                    }
                }
            } else {
                self.onboardingModelActionButton(
                    id: "\(route.id)-download-activate",
                    title: self.onboardingModelActionButtonTitle(isPreparing: false, isDownloaded: false, isReady: false),
                    systemImage: "arrow.down.circle.fill",
                    tone: .primary,
                    width: nil,
                    isDisabled: areModelActionsBlocked
                ) {
                    self.prepareOnboardingRoute(route)
                }
            }
        }
        .padding(16)
        .frame(width: 292, height: 292, alignment: .topLeading)
        .background(
            shape
                .fill(cardFill)
                .overlay(
                    shape.stroke(
                        isSelected
                            ? VibeOnboardingLandingColors.blue.opacity(isHovered ? 0.92 : 0.78)
                            : (isHovered ? Color.white.opacity(0.20) : Color.white.opacity(0.10)),
                        lineWidth: isSelected ? 1.4 : 1
                    )
                )
        )
        .shadow(color: Color.black.opacity(0.34), radius: isHovered ? 20 : 14, x: 0, y: isHovered ? 12 : 8)
        .contentShape(shape)
        .onTapGesture {
            guard !areModelActionsBlocked else { return }
            self.selectOnboardingRoute(route)
        }
        .onHover { isHovered in
            guard enablesHover else { return }
            self.setHoveredModelRoute(isHovered ? route.id : nil)
        }
    }

    private func onboardingModelFeaturePanel(for model: SettingsStore.SpeechModel) -> some View {
        VStack(spacing: 10) {
            self.onboardingModelMetricRow(
                fillPercent: model.speedPercent,
                color: .yellow,
                secondaryColor: AppTheme.VibeBrand.amber,
                icon: "bolt.fill",
                label: "Speed"
            )

            self.onboardingModelMetricRow(
                fillPercent: model.accuracyPercent,
                color: Color.vibeAccent,
                secondaryColor: AppTheme.VibeBrand.blue,
                icon: "target",
                label: "Accuracy"
            )
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Speed \(Int(model.speedPercent * 100)) percent. Accuracy \(Int(model.accuracyPercent * 100)) percent.")
    }

    private func onboardingModelPreparationStatus(isUninstalling: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if self.asr.isCancellingModelPreparation {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .fixedSize()

                    Text("Cancelling...")
                        .font(self.theme.typography.captionStrong)
                        .foregroundStyle(Color.white.opacity(0.62))
                }
            } else if self.asr.isDownloadingModel,
                      self.asr.modelPreparationPhase == .downloading,
                      let progress = self.asr.downloadProgress
            {
                ProgressView(value: progress)
                    .tint(VibeOnboardingLandingColors.blue)

                HStack(spacing: 6) {
                    Text(self.asr.modelPreparationStatusText)
                        .font(self.theme.typography.captionStrong)
                        .foregroundStyle(Color.white.opacity(0.56))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .fixedSize()

                    Text(
                        isUninstalling
                            ? "Deleting..."
                            : self.asr.modelPreparationStatusText
                    )
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(Color.white.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func onboardingModelMetadataRow(badgeText: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let badgeText {
                Label(badgeText, systemImage: "checkmark.seal.fill")
                    .font(self.theme.typography.badge)
                    .foregroundStyle(AppTheme.VibeBrand.mint.opacity(0.92))
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
        }
        .frame(height: badgeText == nil ? 0 : 18, alignment: .leading)
    }

    private func onboardingModelMetricRow(
        fillPercent: Double,
        color: Color,
        secondaryColor: Color,
        icon: String,
        label: String
    ) -> some View {
        let clampedFill = min(max(fillPercent, 0), 1)

        return HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(color)

                Text(label)
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(Color.white.opacity(0.66))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .frame(width: 86, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.075))

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [color, secondaryColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(8, proxy.size.width * CGFloat(clampedFill)))
                        .overlay(
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.24),
                                            Color.clear,
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        )
                }
            }
            .frame(height: 9)

            Text("\(Int(fillPercent * 100))%")
                .font(self.theme.typography.bodySmallStrong)
                .foregroundStyle(fillPercent > 0 ? color : Color.white.opacity(0.48))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .contentTransition(.numericText())
                .frame(width: 46, alignment: .trailing)
        }
        .frame(height: 18)
    }

    private func onboardingModelActionButton(
        id: String,
        title: String,
        systemImage: String,
        tone: OnboardingPillButtonTone = .primary,
        width: CGFloat?,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = self.hoveredModelActionButtonID == id && !isDisabled

        return self.onboardingPillButton(
            configuration: OnboardingPillButtonConfiguration(
                title: title,
                systemImage: systemImage,
                tone: tone,
                width: width,
                height: 36,
                fontSize: 12,
                iconSize: 14,
                isHovered: isHovered,
                isEnabled: !isDisabled
            ),
            action: action
        ) { isHovered in
            self.setHoveredModelActionButton(isHovered ? id : nil)
        }
    }

    private func onboardingPillButton(
        configuration: OnboardingPillButtonConfiguration,
        action: @escaping () -> Void,
        onHover: @escaping (Bool) -> Void
    ) -> some View {
        let shape = Capsule()
        let accentColor: Color = configuration.tone == .destructive ? .red : VibeOnboardingLandingColors.blue
        let isFilledTone = configuration.tone == .primary || configuration.tone == .destructive
        let fillColor: Color = {
            switch configuration.tone {
            case .primary, .destructive:
                return accentColor.opacity(configuration.isEnabled ? 1 : 0.34)
            case .secondary:
                return Color.white.opacity(configuration.isEnabled ? (configuration.isHovered ? 0.11 : 0.07) : 0.045)
            }
        }()
        let borderColor: Color = {
            switch configuration.tone {
            case .primary, .destructive:
                return Color.white.opacity(configuration.isHovered && configuration.isEnabled ? 0.30 : 0)
            case .secondary:
                return configuration.isHovered && configuration.isEnabled ? VibeOnboardingLandingColors.blue.opacity(0.30) : Color.white.opacity(0.07)
            }
        }()
        let foregroundOpacity: Double = configuration.isEnabled ? (isFilledTone ? 1.0 : (configuration.isHovered ? 0.94 : 0.78)) : 0.42
        let shadowOpacity: Double = {
            guard configuration.isEnabled else { return 0 }
            switch configuration.tone {
            case .primary, .destructive:
                return configuration.isHovered ? 0.56 : 0.26
            case .secondary:
                return configuration.isHovered ? 0.08 : 0
            }
        }()
        let ringOpacity: Double = configuration.isHovered && configuration.isEnabled ? 0.50 : 0

        return Button {
            action()
        } label: {
            HStack(spacing: configuration.systemImage == nil ? 0 : 8) {
                if let systemImage = configuration.systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: configuration.iconSize, weight: .bold))
                }

                Text(configuration.title)
                    .font(.system(size: configuration.fontSize, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .foregroundStyle(.white.opacity(foregroundOpacity))
            .frame(width: configuration.width, height: configuration.height)
            .frame(maxWidth: configuration.width == nil ? .infinity : nil)
            .background(
                shape
                    .fill(fillColor)
                    .overlay(shape.fill(Color.white.opacity(isFilledTone && configuration.isHovered && configuration.isEnabled ? 0.10 : 0)))
                    .overlay(shape.stroke(borderColor, lineWidth: configuration.isHovered && configuration.isEnabled ? 1.2 : 1))
                    .overlay(
                        shape
                            .stroke(accentColor.opacity(ringOpacity), lineWidth: configuration.isHovered && configuration.isEnabled ? 1.4 : 1)
                            .padding(-2)
                    )
                    .shadow(color: accentColor.opacity(shadowOpacity), radius: configuration.isHovered && configuration.isEnabled ? 16 : 9, x: 0, y: configuration.isHovered && configuration.isEnabled ? 6 : 3)
            )
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .contentShape(shape)
        .disabled(!configuration.isEnabled)
        .onHover { isHovered in
            onHover(isHovered && configuration.isEnabled)
        }
    }

    private func onboardingModelTooltip(for route: VoiceEngineLanguageRoute) -> String {
        let model = route.model
        return "\(self.onboardingModelSubtitle(for: model)) - \(model.downloadSize)\n\(model.cardDescription)"
    }

    private func onboardingModelTitle(for model: SettingsStore.SpeechModel) -> String {
        model.humanReadableName
    }

    private func onboardingModelSubtitle(for model: SettingsStore.SpeechModel) -> String {
        switch model {
        case .parakeetTDT:
            return "Parakeet v3"
        case .parakeetTDTv2:
            return "Parakeet v2"
        case .parakeetRealtime:
            return "Parakeet Flash"
        case .cohereTranscribeSixBit:
            return "Cohere"
        case .nemotronStreaming:
            return "Nemotron Streaming"
        case .nemotronOffline:
            return "Nemotron Offline"
        case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLarge:
            return "Whisper"
        default:
            return model.displayName
        }
    }

    private func permissionRow(
        stepNumber: Int,
        title: String,
        subtitle: String,
        systemImage: String,
        isReady: Bool,
        statusTitle: String? = nil,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let resolvedStatusTitle = statusTitle ?? (isReady ? "Ready" : "Needed")

        return HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(isReady ? AppTheme.VibeBrand.mint.opacity(0.16) : VibeOnboardingLandingColors.blue.opacity(0.12))
                    .frame(width: 46, height: 46)

                if isReady {
                    Image(systemName: "checkmark")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(AppTheme.VibeBrand.mint.opacity(0.92))
                } else {
                    VStack(spacing: 1) {
                        Image(systemName: systemImage)
                            .font(.system(size: 14, weight: .bold))

                        Text("\(stepNumber)")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(VibeOnboardingLandingColors.blue)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)

                    Text(resolvedStatusTitle)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isReady ? AppTheme.VibeBrand.mint.opacity(0.92) : VibeOnboardingLandingColors.blue)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill((isReady ? AppTheme.VibeBrand.mint : VibeOnboardingLandingColors.blue).opacity(0.12))
                        )
                }

                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(2)
            }

            Spacer()

            if !isReady {
                let actionIcon = ["Open Settings", "Show Guide"].contains(actionTitle) ? "arrow.up.right" : "hand.tap.fill"
                let buttonID = "permission-\(stepNumber)"

                self.onboardingPillButton(
                    configuration: OnboardingPillButtonConfiguration(
                        title: actionTitle,
                        systemImage: actionIcon,
                        tone: .primary,
                        width: 132,
                        height: 36,
                        fontSize: 12,
                        iconSize: 10,
                        isHovered: self.hoveredPermissionButtonID == buttonID,
                        isEnabled: true
                    ),
                    action: action
                ) { isHovered in
                    self.setHoveredPermissionButton(isHovered ? buttonID : nil)
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 88)
        .background(
            shape
                .fill(Color.white.opacity(isReady ? 0.045 : 0.070))
                .overlay(
                    shape.stroke(
                        isReady ? AppTheme.VibeBrand.mint.opacity(0.18) : VibeOnboardingLandingColors.blue.opacity(0.26),
                        lineWidth: 1
                    )
                )
        )
    }

    private func isOnboardingRouteSelected(_ route: VoiceEngineLanguageRoute) -> Bool {
        self.selectedOnboardingRoute?.id == route.id || self.isRouteSelectedInSettings(route)
    }

    private func isRouteSelectedInSettings(_ route: VoiceEngineLanguageRoute) -> Bool {
        guard route.model == self.settings.selectedSpeechModel else {
            return false
        }

        switch route.binding {
        case .automatic, .whisper:
            return self.settings.onboardingSelectedLanguageID == route.language.id
        case let .appleSpeech(localeIdentifier):
            return self.settings.selectedAppleSpeechLocaleIdentifier == localeIdentifier
        case let .cohere(language):
            return self.settings.selectedCohereLanguage == language
        case let .nemotron(language):
            return self.settings.selectedNemotronLanguage == language
        }
    }

    private func isRouteModelAndLanguageSettingsSelected(_ route: VoiceEngineLanguageRoute) -> Bool {
        guard route.model == self.settings.selectedSpeechModel else {
            return false
        }

        switch route.binding {
        case .automatic, .whisper:
            return true
        case let .appleSpeech(localeIdentifier):
            return self.settings.selectedAppleSpeechLocaleIdentifier == localeIdentifier
        case let .cohere(language):
            return self.settings.selectedCohereLanguage == language
        case let .nemotron(language):
            return self.settings.selectedNemotronLanguage == language
        }
    }

    private func selectOnboardingRoute(_ route: VoiceEngineLanguageRoute) {
        let oldModel = self.settings.selectedSpeechModel
        let oldAppleSpeechLocaleIdentifier = self.settings.selectedAppleSpeechLocaleIdentifier
        let oldCohereLanguage = self.settings.selectedCohereLanguage
        let oldNemotronLanguage = self.settings.selectedNemotronLanguage

        self.selectedModelRouteID = route.id
        VoiceEngineLanguageCatalog.apply(route, to: self.settings)

        let languageChanged: Bool
        switch route.binding {
        case .automatic, .whisper:
            languageChanged = false
        case .appleSpeech:
            languageChanged = oldAppleSpeechLocaleIdentifier != self.settings.selectedAppleSpeechLocaleIdentifier
        case .cohere:
            languageChanged = oldCohereLanguage != self.settings.selectedCohereLanguage
        case .nemotron:
            languageChanged = oldNemotronLanguage != self.settings.selectedNemotronLanguage
        }

        if oldModel != self.settings.selectedSpeechModel || languageChanged {
            self.resetTryoutValidationForSetupChange()
            self.asr.resetTranscriptionProvider()
        }
    }

    private func setHoveredModelRoute(_ routeID: String?) {
        guard self.hoveredModelRouteID != routeID else { return }
        if self.reduceMotion {
            self.hoveredModelRouteID = routeID
        } else {
            withAnimation(.easeOut(duration: 0.14)) {
                self.hoveredModelRouteID = routeID
            }
        }
    }

    private func setHoveredModelActionButton(_ buttonID: String?) {
        guard self.hoveredModelActionButtonID != buttonID else { return }
        if self.reduceMotion {
            self.hoveredModelActionButtonID = buttonID
        } else {
            withAnimation(.easeOut(duration: 0.14)) {
                self.hoveredModelActionButtonID = buttonID
            }
        }
    }

    private func setHoveredPermissionButton(_ buttonID: String?) {
        guard self.hoveredPermissionButtonID != buttonID else { return }
        if self.reduceMotion {
            self.hoveredPermissionButtonID = buttonID
        } else {
            withAnimation(.easeOut(duration: 0.14)) {
                self.hoveredPermissionButtonID = buttonID
            }
        }
    }

    private func togglePrimaryShortcutRecording() {
        guard !self.asr.isRunning else { return }
        if self.isRecordingPrimaryShortcut {
            self.activeShortcutRecordingTarget = nil
            self.shortcutRecordingMessage = nil
        } else {
            self.shortcutRecordingMessage = nil
            self.activeShortcutRecordingTarget = .primaryDictation(.replace(0))
        }
    }

    private func resetTryoutValidationForSetupChange() {
        self.settings.onboardingPlaygroundValidated = false
        self.settings.onboardingPlaygroundSkipped = false
        self.settings.playgroundUsed = false
        self.asr.finalText = ""
    }

    private func handleMicrophoneAction() {
        if self.asr.micStatus == .notDetermined {
            self.asr.requestMicAccess()
        } else {
            self.asr.openSystemSettingsForMic()
        }
    }

    private func goBack() {
        self.activeShortcutRecordingTarget = nil
        self.shortcutRecordingMessage = nil
        self.currentStep = max(0, self.currentStep - 1)
    }

    private func goNext() {
        self.activeShortcutRecordingTarget = nil
        self.shortcutRecordingMessage = nil
        self.currentStep = min(Step.allCases.count - 1, self.currentStep + 1)
    }

    private func handlePrimaryAction() {
        guard !self.isModelPreparationInProgress else {
            return
        }

        if self.step == .language, let route = self.selectedOnboardingRoute {
            self.selectOnboardingRoute(route)
        }

        if self.step == .playground {
            guard self.isPlaygroundReady else { return }
            self.finishOnboarding()
            return
        }
        self.goNext()
    }
}
