//
//  SettingsView.swift
//  VebeVoice
//
//  App preferences and audio device settings
//

import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    private struct ShortcutRowContent {
        let icon: String
        let iconColor: Color
        let title: String
        let description: String
    }

    /// Focused page within Settings (General / Keyboard Shortcuts / Overlay).
    let pageScope: SettingsPageScope

    @EnvironmentObject var appServices: AppServices
    private var asr: ASRService {
        self.appServices.asr
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.theme) private var theme
    @ObservedObject private var settings = SettingsStore.shared
    @Binding var appear: Bool
    @Binding var visualizerNoiseThreshold: Double
    @Binding var selectedInputUID: String
    @Binding var selectedOutputUID: String
    @Binding var microphoneSelectionMode: SettingsStore.MicrophoneSelectionMode
    @Binding var inputDevices: [AudioDevice.Device]
    @Binding var outputDevices: [AudioDevice.Device]
    @Binding var accessibilityEnabled: Bool
    @Binding var primaryDictationShortcuts: [HotkeyShortcut]
    @Binding var activeShortcutRecordingTarget: ShortcutRecordingTarget?
    @Binding var shortcutRecordingMessage: String?
    @Binding var cancelRecordingShortcut: HotkeyShortcut
    @Binding var pasteLastTranscriptionShortcut: HotkeyShortcut?
    @Binding var pasteLastTranscriptionShortcutEnabled: Bool
    @Binding var hotkeyManagerInitialized: Bool
    @Binding var hotkeyMode: HotkeyActivationMode
    @Binding var enableStreamingPreview: Bool
    @Binding var copyToClipboard: Bool

    // CRITICAL FIX: Cache default device names to avoid CoreAudio calls during view body evaluation.
    // Querying AudioDevice.getDefaultInputDevice() in the view body triggers HALSystem::InitializeShell()
    // which races with SwiftUI's AttributeGraph metadata processing and causes EXC_BAD_ACCESS crashes.
    @State private var cachedDefaultInputName: String = ""
    @State private var cachedDefaultOutputName: String = ""

    @State private var audioHistoryBudgetText: String = Self.audioBudgetText(for: SettingsStore.shared.audioHistoryBudgetGB)
    @State private var audioHistoryUsageBytes: Int64 = DictationAudioHistoryStore.shared.audioUsageBytes()

    let hotkeyManager: GlobalHotkeyManager?
    let refreshDevices: () -> Void
    let openAccessibilitySettings: () -> Void
    let revealAppInFinder: () -> Void
    let openApplicationsFolder: () -> Void

    private var inputDeviceSelection: Binding<String> {
        Binding(
            get: { self.selectedInputUID },
            set: { newUID in
                guard !newUID.isEmpty else { return }
                guard !self.asr.isRunning else {
                    DebugLogger.shared.warning(
                        "Cannot change input device during recording",
                        source: "SettingsView"
                    )
                    return
                }

                self.selectedInputUID = newUID
                SettingsStore.shared.recordInputDeviceSelection(newUID)
                if SettingsStore.shared.shouldSyncInputSelectionToSystemDefault() {
                    _ = AudioDevice.setDefaultInputDevice(uid: newUID)
                }
            }
        )
    }

    private var isRecordingAnyShortcut: Bool {
        self.activeShortcutRecordingTarget != nil
    }

    private var settingsTitleText: Color {
        Color(nsColor: .labelColor)
    }

    private var settingsSecondaryText: Color {
        self.colorScheme == .light ? Color(nsColor: .labelColor).opacity(0.90) : self.theme.palette.primaryText.opacity(0.82)
    }

    private var settingsTertiaryText: Color {
        self.colorScheme == .light ? Color(nsColor: .labelColor).opacity(0.85) : self.theme.palette.secondaryText
    }

    private func isRecording(_ target: ShortcutRecordingTarget) -> Bool {
        self.activeShortcutRecordingTarget == target
    }

    private var appDisplayName: String {
        Bundle.main.vibeAppDisplayName
    }

    private var launchAtStartupBinding: Binding<Bool> {
        Binding(
            get: { self.settings.launchAtStartupEnabled },
            set: { self.settings.setLaunchAtStartup($0) }
        )
    }

    var body: some View {
        SettingsPersistentScrollView(theme: self.theme, colorScheme: self.colorScheme) {
            VStack(alignment: .leading, spacing: VibePageLayout.sectionSpacing) {
                // General (launch, appearance, sounds)
                if self.pageScope == .general {
                self.settingsGroup(title: nil, systemImage: nil) {
                    VStack(spacing: 0) {
                        // Launch at startup
                        self.settingsToggleRow(
                            title: "Launch at startup",
                            description: "Automatically start VebeVoice when you log in",
                            footnote: self.settings.launchAtStartupStatusMessage,
                            errorMessage: self.settings.launchAtStartupErrorMessage,
                            isOn: self.launchAtStartupBinding
                        )
                        self.settingsRowDivider()

                        // Show window when launched at login
                        self.settingsToggleRow(
                            title: "Show window when launched at login",
                            description: "When off, VebeVoice starts silently in the menu bar at login. Opening the app yourself always shows the window.",
                            isOn: Binding(
                                get: { SettingsStore.shared.showMainWindowAtLoginLaunch },
                                set: { SettingsStore.shared.showMainWindowAtLoginLaunch = $0 }
                            )
                        )
                        self.settingsRowDivider()

                        // Hide from Dock & App Switcher
                        self.settingsToggleRow(
                            title: "Hide from Dock & App Switcher",
                            description: "Keep VebeVoice in the menu bar only (hides Dock icon and Cmd+Tab entry)",
                            footnote: "May require an app restart to take effect.",
                            isOn: Binding(
                                get: { SettingsStore.shared.hideFromDockAndAppSwitcher },
                                set: { SettingsStore.shared.hideFromDockAndAppSwitcher = $0 }
                            )
                        )
                        self.settingsRowDivider()

                        // Accent Color
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Accent Color")
                                    .font(self.theme.typography.bodyStrong)
                                    .foregroundStyle(self.settingsTitleText)
                                Text("Purple spectrum accents for controls and highlights.")
                                    .font(self.theme.typography.bodySmall)
                                    .foregroundStyle(self.settingsSecondaryText)
                            }

                            Spacer(minLength: 12)

                            HStack(spacing: 8) {
                                ForEach(SettingsStore.AccentColorOption.allCases) { option in
                                    let isSelected = self.settings.accentColorOption == option
                                    Button {
                                        self.settings.accentColorOption = option
                                    } label: {
                                        Circle()
                                            .fill(option.color)
                                            .frame(width: 18, height: 18)
                                            .overlay(
                                                Circle()
                                                    .strokeBorder(
                                                        isSelected ? Color.white.opacity(0.95) : Color.white.opacity(0.12),
                                                        lineWidth: isSelected ? 2 : 1
                                                    )
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(option.rawValue)
                                    .help(option.rawValue)
                                }
                            }
                        }
                        .padding(.vertical, 4)

                        self.settingsRowDivider()

                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Transcription Sounds")
                                        .font(self.theme.typography.bodyStrong)
                                        .foregroundStyle(self.settingsTitleText)
                                    Text("Choose the sound cue for recording. Some cues include an end sound.")
                                        .font(self.theme.typography.bodySmall)
                                        .foregroundStyle(self.settingsSecondaryText)
                                }

                                Spacer()

                                Picker("", selection: Binding(
                                    get: { SettingsStore.shared.transcriptionStartSound },
                                    set: { newValue in
                                        SettingsStore.shared.transcriptionStartSound = newValue
                                        TranscriptionSoundPlayer.shared.playPreview(sound: newValue)
                                    }
                                )) {
                                    ForEach(SettingsStore.TranscriptionStartSound.allCases) { option in
                                        Text(option.displayName).tag(option)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 170, alignment: .trailing)
                            }

                            if SettingsStore.shared.transcriptionStartSound != .none {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Volume")
                                            .font(self.theme.typography.bodyStrong)
                                            .foregroundStyle(self.settingsTitleText)
                                        Text("Adjust the recording sound cue volume.")
                                            .font(self.theme.typography.bodySmall)
                                            .foregroundStyle(self.settingsSecondaryText)
                                    }

                                    Spacer()

                                    Slider(
                                        value: Binding(
                                            get: { Double(SettingsStore.shared.transcriptionSoundVolume) },
                                            set: { SettingsStore.shared.transcriptionSoundVolume = Float($0) }
                                        ),
                                        in: 0...1,
                                        step: 0.05
                                    ) { editing in
                                        if !editing {
                                            TranscriptionSoundPlayer.shared.playPreviewAtVolume(
                                                SettingsStore.shared.transcriptionSoundVolume
                                            )
                                        }
                                    }
                                    .frame(width: 150)
                                }

                                self.settingsToggleRow(
                                    title: "Independent Volume",
                                    description: "Sound volume stays constant regardless of system volume. Mute is still respected.",
                                    footnote: "Temporarily changes system volume during playback, which may briefly affect other audio.",
                                    isOn: Binding(
                                        get: { SettingsStore.shared.transcriptionSoundIndependentVolume },
                                        set: { SettingsStore.shared.transcriptionSoundIndependentVolume = $0 }
                                    )
                                )
                            }
                    }
                }
                } // pageScope == .general (General group)

                // Microphone
                if self.pageScope == .general {
                self.settingsGroup(title: "Microphone", systemImage: "mic.fill") {
                    VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(self.asr.micStatus == .authorized ? self.theme.palette.success : self.theme.palette.warning)
                                    .frame(width: 8, height: 8)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(
                                        self.asr.micStatus == .authorized ? "Access granted" :
                                            self.asr.micStatus == .denied ? "Access denied" :
                                            "Not determined"
                                    )
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(self.asr.micStatus == .authorized ? self.settingsTitleText : self.theme.palette.warning)

                                    if self.asr.micStatus != .authorized {
                                        Text("Required for voice recording.")
                                            .font(.system(size: 12, weight: .regular))
                                            .foregroundStyle(self.settingsSecondaryText)
                                    }
                                }
                                Spacer(minLength: 12)

                                if self.asr.micStatus == .notDetermined {
                                    Button {
                                        self.asr.requestMicAccess()
                                    } label: {
                                        Label("Grant Access", systemImage: "mic.fill")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(self.theme.palette.accent)
                                    .controlSize(.regular)
                                } else if self.asr.micStatus == .denied {
                                    Button {
                                        self.asr.openSystemSettingsForMic()
                                    } label: {
                                        Label("Open Settings", systemImage: "gear")
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.regular)
                                }
                            }

                            if self.asr.micStatus != .authorized {
                                self.instructionsBox(
                                    title: "How to enable microphone access:",
                                    steps: self.asr.micStatus == .notDetermined
                                        ? ["Click **Grant Access** above", "Choose **Allow** in the system dialog"]
                                        : [
                                            "Click **Open Settings** above",
                                            "Find **\(self.appDisplayName)** in the microphone list",
                                            "Toggle **\(self.appDisplayName) ON** to allow access",
                                        ]
                                )
                            }
                    }
                }
                } // pageScope == .general (Microphone)

                // Shortcuts (own sidebar destination)
                if self.pageScope == .keyboardShortcuts {
                self.settingsGroup(title: nil, systemImage: nil) {
                    VStack(alignment: .leading, spacing: 14) {
                        if self.accessibilityEnabled {
                            HStack {
                                Spacer()
                                if self.isRecordingAnyShortcut {
                                    Text("Recording…")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(AppTheme.VibeBrand.amber)
                                } else if self.hotkeyManagerInitialized {
                                    HStack(spacing: 5) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(self.theme.palette.success)
                                            .font(.caption)
                                        Text("Active")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(self.settingsSecondaryText)
                                    }
                                } else {
                                    Text("Initializing…")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(self.settingsSecondaryText)
                                }
                            }
                        }

                        if self.accessibilityEnabled {
                            VStack(alignment: .leading, spacing: 12) {
                                if self.isRecordingAnyShortcut {
                                    HStack(spacing: 8) {
                                        Image(systemName: "hand.point.up.left.fill")
                                            .foregroundStyle(AppTheme.VibeBrand.amber)
                                        Text("Press your new hotkey combination now…")
                                            .font(.caption)
                                            .foregroundStyle(AppTheme.VibeBrand.amber)
                                    }
                                } else if !self.hotkeyManagerInitialized {
                                    HStack(spacing: 8) {
                                        ProgressView()
                                            .controlSize(.small)
                                            .fixedSize()
                                        Text("Hotkey initializing…")
                                            .font(.caption)
                                            .foregroundStyle(self.settingsSecondaryText)
                                    }
                                }

                                // MARK: - Shortcuts Section

                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Shortcuts")
                                        .font(self.theme.typography.bodySmallStrong)
                                        .foregroundStyle(self.settingsTitleText)

                                    Text("Primary dictation can use a keyboard shortcut or allowed mouse button. Changes usually apply immediately.")
                                        .font(.caption)
                                        .foregroundStyle(self.settingsTertiaryText)

                                    self.primaryDictationShortcutsList()
                                    Divider().opacity(0.2).padding(.vertical, 4)

                                    self.shortcutRow(
                                        content: .init(
                                            icon: "xmark.circle.fill",
                                            iconColor: .secondary,
                                            title: "Cancel Recording",
                                            description: "Cancel the current recording or dismiss the active recording overlay"
                                        ),
                                        shortcut: self.cancelRecordingShortcut,
                                        isRecording: self.isRecording(.cancel),
                                        isAnyRecordingActive: self.isRecordingAnyShortcut,
                                        recordingMessage: self.isRecording(.cancel) ? self.shortcutRecordingMessage : nil,
                                        onChangePressed: {
                                            DebugLogger.shared.debug("Starting to record new cancel shortcut", source: "SettingsView")
                                            self.shortcutRecordingMessage = nil
                                            self.activeShortcutRecordingTarget = .cancel
                                        }
                                    )
                                    Divider().opacity(0.2).padding(.vertical, 4)

                                    self.shortcutRow(
                                        content: .init(
                                            icon: "arrow.down.doc",
                                            iconColor: .secondary,
                                            title: "Paste Last Transcription",
                                            description: "Re-insert your most recent transcription without using the clipboard"
                                        ),
                                        shortcut: self.pasteLastTranscriptionShortcut,
                                        isRecording: self.isRecording(.pasteLast),
                                        isAnyRecordingActive: self.isRecordingAnyShortcut,
                                        recordingMessage: self.isRecording(.pasteLast) ? self.shortcutRecordingMessage : nil,
                                        isEnabled: self.$pasteLastTranscriptionShortcutEnabled,
                                        requiresShortcutToEnable: true,
                                        onChangePressed: {
                                            DebugLogger.shared.debug("Starting to record new paste last transcription shortcut", source: "SettingsView")
                                            self.shortcutRecordingMessage = nil
                                            self.activeShortcutRecordingTarget = .pasteLast
                                        },
                                        onRemovePressed: {
                                            if self.activeShortcutRecordingTarget == .pasteLast {
                                                self.shortcutRecordingMessage = nil
                                                self.activeShortcutRecordingTarget = nil
                                            }
                                            self.pasteLastTranscriptionShortcut = nil
                                            self.pasteLastTranscriptionShortcutEnabled = false
                                        }
                                    )
                                }
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(self.theme.palette.elevatedCardBackground)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .stroke(self.theme.palette.cardBorder.opacity(0.45), lineWidth: 1)
                                        )
                                )

                                // MARK: - Options Section

                                VStack(spacing: 12) {
                                    HStack(alignment: .center) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Activation Mode")
                                                .font(self.theme.typography.bodyStrong)
                                                .foregroundStyle(self.settingsTitleText)
                                            Text(self.hotkeyMode.description)
                                                .font(self.theme.typography.bodySmall)
                                                .foregroundStyle(self.settingsSecondaryText)
                                        }

                                        Spacer()

                                        Picker("", selection: self.$hotkeyMode) {
                                            ForEach(HotkeyActivationMode.allCases) { mode in
                                                Text(mode.displayName).tag(mode)
                                            }
                                        }
                                        .pickerStyle(.menu)
                                        .frame(width: 170, alignment: .trailing)
                                    }
                                    .onChange(of: self.hotkeyMode) { _, newValue in
                                        SettingsStore.shared.hotkeyMode = newValue
                                        self.hotkeyManager?.setHotkeyMode(newValue)
                                    }
                                    Divider().opacity(0.2)

                                    self.optionToggleRow(
                                        title: "Copy to Clipboard",
                                        description: "Automatically copy transcribed text to clipboard as a backup.",
                                        isOn: self.$copyToClipboard
                                    )
                                    .onChange(of: self.copyToClipboard) { _, newValue in
                                        SettingsStore.shared.copyTranscriptionToClipboard = newValue
                                    }
                                    Divider().opacity(0.2)

                                    HStack(alignment: .center) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Text Insertion Mode")
                                                .font(self.theme.typography.bodyStrong)
                                                .foregroundStyle(self.settingsTitleText)
                                            Text(SettingsStore.shared.textInsertionMode.description)
                                                .font(self.theme.typography.bodySmall)
                                                .foregroundStyle(self.settingsSecondaryText)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }

                                        Spacer()

                                        Picker("", selection: Binding(
                                            get: { SettingsStore.shared.textInsertionMode },
                                            set: { SettingsStore.shared.textInsertionMode = $0 }
                                        )) {
                                            ForEach(SettingsStore.TextInsertionMode.allCases) { mode in
                                                Text(mode.displayName).tag(mode)
                                            }
                                        }
                                        .pickerStyle(.menu)
                                        .frame(width: 170, alignment: .trailing)
                                    }
                                    Divider().opacity(0.2)

                                    self.optionToggleRow(
                                        title: "Save Transcription History",
                                        description: "Save transcriptions for stats tracking. Disable for privacy.",
                                        isOn: Binding(
                                            get: { SettingsStore.shared.saveTranscriptionHistory },
                                            set: {
                                                SettingsStore.shared.saveTranscriptionHistory = $0
                                                self.refreshAudioHistoryUsage()
                                            }
                                        )
                                    )
                                    Divider().opacity(0.2)

                                    self.optionToggleRow(
                                        title: "Save Audio With History",
                                        description: "Store actual microphone audio locally with dictation history. Disabled by default.",
                                        isOn: Binding(
                                            get: { SettingsStore.shared.saveAudioWithTranscriptionHistory },
                                            set: {
                                                SettingsStore.shared.saveAudioWithTranscriptionHistory = $0
                                                self.refreshAudioHistoryUsage()
                                            }
                                        )
                                    )
                                    .disabled(!SettingsStore.shared.saveTranscriptionHistory)

                                    if SettingsStore.shared.saveTranscriptionHistory,
                                       SettingsStore.shared.saveAudioWithTranscriptionHistory
                                    {
                                        self.audioHistoryControls()
                                            .padding(.top, 2)
                                        Divider().opacity(0.2)
                                    } else {
                                        Divider().opacity(0.2)
                                    }

                                    self.optionToggleRow(
                                        title: "Weekends Don't Break Streak",
                                        description: "Skip Saturday and Sunday when calculating usage streaks. Perfect for weekday-only users.",
                                        isOn: Binding(
                                            get: { SettingsStore.shared.weekendsDontBreakStreak },
                                            set: { SettingsStore.shared.weekendsDontBreakStreak = $0 }
                                        )
                                    )
                                    Divider().opacity(0.2)

                                    self.optionToggleRow(
                                        title: "Lowercase First Letter",
                                        description: "Start each transcription with a lowercase letter. Useful for search queries, form fields, or casual text.",
                                        isOn: Binding(
                                            get: { SettingsStore.shared.gaavLowercaseFirstLetterEnabled },
                                            set: { SettingsStore.shared.gaavLowercaseFirstLetterEnabled = $0 }
                                        )
                                    )
                                    Divider().opacity(0.2)

                                    self.optionToggleRow(
                                        title: "Remove Trailing Period",
                                        description: "Drop a final period from transcriptions. Useful for chat messages, search boxes, and commit titles.",
                                        isOn: Binding(
                                            get: { SettingsStore.shared.gaavRemoveTrailingPeriodEnabled },
                                            set: { SettingsStore.shared.gaavRemoveTrailingPeriodEnabled = $0 }
                                        )
                                    )
                                    Divider().opacity(0.2)

                                    self.optionToggleRow(
                                        title: "Slash Commands & @ Formatting",
                                        description: "When on, \"slash status\" becomes \"/status\"; \"tag Paul\", \"mention Paul\", \"at sign Paul\", and \"at the rate Paul\" become \"@Paul\". " +
                                            "In chat apps, \"at Paul\" also works. Turn it off to leave all of these unchanged.",
                                        isOn: Binding(
                                            get: { SettingsStore.shared.literalDictationFormattingEnabled },
                                            set: { SettingsStore.shared.literalDictationFormattingEnabled = $0 }
                                        ),
                                        allowsDescriptionWrapping: true
                                    )
                                    Divider().opacity(0.2)

                                    self.optionToggleRow(
                                        title: "Space Between Dictations",
                                        description: "Add spacing so consecutive dictations chain without manually pressing the spacebar.",
                                        isOn: Binding(
                                            get: { SettingsStore.shared.continuousDictationSpacingEnabled },
                                            set: { SettingsStore.shared.continuousDictationSpacingEnabled = $0 }
                                        )
                                    )
                                    Divider().opacity(0.2)

                                    self.optionToggleRow(
                                        title: "Smart Capitalization",
                                        description: "Use text before the cursor to decide whether the next dictation should start capitalized or lowercase.",
                                        isOn: Binding(
                                            get: { SettingsStore.shared.contextAwareCapitalizationEnabled },
                                            set: { SettingsStore.shared.contextAwareCapitalizationEnabled = $0 }
                                        )
                                    )
                                    Divider().opacity(0.2)

                                    self.optionToggleRow(
                                        title: "Pause Media During Transcription",
                                        description: "Automatically pause currently playing audio/video when transcription starts. Resumes only if VebeVoice paused it.",
                                        isOn: Binding(
                                            get: { SettingsStore.shared.pauseMediaDuringTranscription },
                                            set: { SettingsStore.shared.pauseMediaDuringTranscription = $0 }
                                        )
                                    )
                                }
                                .padding(12)
                            }
                        } else {
                            // Hotkey disabled - accessibility not enabled
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(self.theme.palette.warning)
                                        .frame(width: 8, height: 8)

                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .foregroundStyle(self.theme.palette.warning)
                                            Text("Accessibility permissions required")
                                                .font(self.theme.typography.bodyStrong)
                                                .foregroundStyle(self.theme.palette.warning)
                                        }
                                        Text("Required for global hotkey functionality")
                                            .font(self.theme.typography.bodySmall)
                                            .foregroundStyle(self.settingsSecondaryText)
                                    }
                                    Spacer()

                                    Button("Open Accessibility Settings") {
                                        self.openAccessibilitySettings()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(self.theme.palette.accent)
                                    .controlSize(.regular)
                                }

                                self.instructionsBox(
                                    title: "Follow these steps to enable Accessibility:",
                                    steps: [
                                        "Click **Open Accessibility Settings** above",
                                        "In the Accessibility window, click the **+ button**",
                                        "Select **\(self.appDisplayName)**; use **Reveal in Finder** below if needed",
                                        "Click **Open**, then toggle **\(self.appDisplayName) ON** in the list",
                                    ],
                                    warningStyle: true
                                )

                                HStack(spacing: 10) {
                                    Button("Reveal in Finder") {
                                        self.revealAppInFinder()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    Button("Open Applications") {
                                        self.openApplicationsFolder()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }
                } // pageScope == .keyboardShortcuts

                // Audio Devices
                if self.pageScope == .general {
                self.settingsGroup(title: "Audio Devices", systemImage: "speaker.wave.2.fill") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Spacer()

                            Button {
                                self.refreshDevices()                                // Update cached default device names on refresh
                                self.cachedDefaultInputName = AudioDevice.getDefaultInputDevice()?.name ?? ""
                                self.cachedDefaultOutputName = AudioDevice.getDefaultOutputDevice()?.name ?? ""
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        // Info note about device syncing
                        self.microphoneModeInfo

                        VStack(alignment: .leading, spacing: 12) {
                            self.microphoneModeToggle

                            HStack {
                                Text("Input Device")
                                    .font(self.theme.typography.bodyStrong)
                                    .foregroundStyle(self.settingsTitleText)
                                Spacer()
                                Picker("", selection: self.inputDeviceSelection) {
                                    // Handle empty state gracefully
                                    if self.inputDevices.isEmpty {
                                        Text("Loading...").tag("")
                                    } else {
                                        ForEach(self.inputDevices, id: \.uid) { dev in
                                            // Add "(System Default)" tag using cached name to avoid CoreAudio calls during layout
                                            let isSystemDefault = !self.cachedDefaultInputName.isEmpty && dev.name == self.cachedDefaultInputName
                                            Text(isSystemDefault ? "\(dev.name) (System Default)" : dev.name).tag(dev.uid)
                                        }
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 240)
                                .disabled(self.asr.isRunning)
                                // Sync selection when devices load or change
                                .onChange(of: self.inputDevices) { _, newDevices in
                                    // Update cached default device name when device list changes
                                    self.cachedDefaultInputName = AudioDevice.getDefaultInputDevice()?.name ?? ""

                                    guard !newDevices.isEmpty else { return }

                                    switch self.microphoneSelectionMode {
                                    case .system:
                                        if let defaultUID = AudioDevice.getDefaultInputDevice()?.uid,
                                           newDevices.contains(where: { $0.uid == defaultUID })
                                        {
                                            self.selectedInputUID = defaultUID
                                        } else if !newDevices.contains(where: { $0.uid == self.selectedInputUID }) {
                                            self.selectedInputUID = newDevices.first?.uid ?? ""
                                        }
                                    case .manual:
                                        if let preferredUID = SettingsStore.shared.preferredInputDeviceUID,
                                           newDevices.contains(where: { $0.uid == preferredUID })
                                        {
                                            self.selectedInputUID = preferredUID
                                        } else if let defaultUID = AudioDevice.getDefaultInputDevice()?.uid,
                                                  newDevices.contains(where: { $0.uid == defaultUID })
                                        {
                                            self.selectedInputUID = defaultUID
                                        } else {
                                            self.selectedInputUID = newDevices.first?.uid ?? ""
                                        }
                                    }
                                }
                            }

                            HStack {
                                Text("Output Device")
                                    .font(self.theme.typography.bodyStrong)
                                    .foregroundStyle(self.settingsTitleText)
                                Spacer()
                                Picker("", selection: self.$selectedOutputUID) {
                                    // Handle empty state gracefully
                                    if self.outputDevices.isEmpty {
                                        Text("Loading...").tag("")
                                    } else {
                                        ForEach(self.outputDevices, id: \.uid) { dev in
                                            // Add "(System Default)" tag using cached name to avoid CoreAudio calls during layout
                                            let isSystemDefault = !self.cachedDefaultOutputName.isEmpty && dev.name == self.cachedDefaultOutputName
                                            Text(isSystemDefault ? "\(dev.name) (System Default)" : dev.name).tag(dev.uid)
                                        }
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 240)
                                .disabled(self.asr.isRunning) // Disable device changes during recording
                                .onChange(of: self.selectedOutputUID) { oldUID, newUID in
                                    guard !newUID.isEmpty else { return }

                                    // Prevent device changes during active recording
                                    if self.asr.isRunning {
                                        DebugLogger.shared.warning("Cannot change output device during recording", source: "SettingsView")
                                        // Revert to previous value
                                        self.selectedOutputUID = oldUID
                                        return
                                    }

                                    SettingsStore.shared.preferredOutputDeviceUID = newUID
                                    _ = AudioDevice.setDefaultOutputDevice(uid: newUID)
                                }
                                // Sync selection when devices load or change
                                .onChange(of: self.outputDevices) { _, newDevices in
                                    // Update cached default device name when device list changes
                                    self.cachedDefaultOutputName = AudioDevice.getDefaultOutputDevice()?.name ?? ""

                                    if !newDevices.isEmpty {
                                        let currentValid = newDevices.contains { $0.uid == self.selectedOutputUID }
                                        if !currentValid {
                                            if let prefUID = SettingsStore.shared.preferredOutputDeviceUID,
                                               newDevices.contains(where: { $0.uid == prefUID })
                                            {
                                                self.selectedOutputUID = prefUID
                                            } else if let defaultUID = AudioDevice.getDefaultOutputDevice()?.uid,
                                                      newDevices.contains(where: { $0.uid == defaultUID })
                                            {
                                                self.selectedOutputUID = defaultUID
                                            } else {
                                                self.selectedOutputUID = newDevices.first?.uid ?? ""
                                            }
                                        }
                                    }
                                }
                            }

                            // CRITICAL FIX: Use cached values instead of querying CoreAudio in view body.
                            // Querying AudioDevice here triggers HALSystem::InitializeShell() race condition.
                            if !self.cachedDefaultInputName.isEmpty && !self.cachedDefaultOutputName.isEmpty {
                                HStack {
                                    Spacer()
                                    Text("Default: \(self.cachedDefaultInputName) / \(self.cachedDefaultOutputName)")
                                        .font(.caption)
                                        .foregroundStyle(self.settingsTertiaryText)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
                } // pageScope == .general (Audio Devices)

                // Overlay (own sidebar destination) — no redundant section title
                if self.pageScope == .overlay {
                self.settingsGroup(title: nil, systemImage: nil) {
                    VStack(alignment: .leading, spacing: 12) {
                            // Overlay look follows the same light/dark control as the app (sidebar footer sun/moon).
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Overlay look")
                                        .font(self.theme.typography.bodyStrong)
                                        .foregroundStyle(self.settingsTitleText)
                                    Text("Dictation pill and menus use Light, Dark, or System — same as the app theme.")
                                        .font(self.theme.typography.bodySmall)
                                        .foregroundStyle(self.settingsSecondaryText)
                                }
                                Spacer()
                                Picker("", selection: Binding(
                                    get: { SettingsStore.shared.themePreference },
                                    set: { SettingsStore.shared.themePreference = $0 }
                                )) {
                                    ForEach(SettingsStore.ThemePreference.allCases) { preference in
                                        Text(preference.displayName).tag(preference)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 120)
                            }

                            Divider().padding(.vertical, 4)

                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Sensitivity")
                                        .font(self.theme.typography.bodyStrong)
                                        .foregroundStyle(self.settingsTitleText)
                                    Text("Control how sensitive the audio visualizer is to sound input")
                                        .font(self.theme.typography.bodySmall)
                                        .foregroundStyle(self.settingsSecondaryText)
                                }

                                Spacer()

                                Button("Reset") {
                                    self.visualizerNoiseThreshold = 0.4
                                    SettingsStore.shared.visualizerNoiseThreshold = self.visualizerNoiseThreshold
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            HStack(spacing: 10) {
                                Text("More")
                                    .font(.caption)
                                    .foregroundStyle(self.settingsSecondaryText)
                                    .frame(width: 36, alignment: .trailing)

                                Slider(value: self.$visualizerNoiseThreshold, in: 0.01...0.8, step: 0.01)
                                    .controlSize(.regular)

                                Text("Less")
                                    .font(.caption)
                                    .foregroundStyle(self.settingsSecondaryText)
                                    .frame(width: 36, alignment: .leading)

                                Text(String(format: "%.2f", self.visualizerNoiseThreshold))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(self.settingsTertiaryText)
                                    .frame(width: 36)
                            }

                            Divider().padding(.vertical, 8)

                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Transcription Preview Length")
                                            .font(self.theme.typography.bodyStrong)
                                            .foregroundStyle(self.settingsTitleText)
                                        Text("How many recent characters appear in the notch/pill preview")
                                            .font(self.theme.typography.bodySmall)
                                            .foregroundStyle(self.settingsSecondaryText)
                                    }

                                    Spacer()

                                    Text("\(self.settings.transcriptionPreviewCharLimit) chars")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(self.settingsSecondaryText)
                                }

                                HStack(spacing: 10) {
                                    Text("Less")
                                        .font(.caption)
                                        .foregroundStyle(self.settingsSecondaryText)
                                        .frame(width: 36, alignment: .trailing)

                                    Slider(
                                        value: Binding(
                                            get: { Double(self.settings.transcriptionPreviewCharLimit) },
                                            set: { self.settings.transcriptionPreviewCharLimit = Int($0.rounded()) }
                                        ),
                                        in: Double(SettingsStore.transcriptionPreviewCharLimitRange.lowerBound)...Double(SettingsStore.transcriptionPreviewCharLimitRange.upperBound),
                                        step: Double(SettingsStore.transcriptionPreviewCharLimitStep)
                                    )
                                    .controlSize(.regular)

                                    Text("More")
                                        .font(.caption)
                                        .foregroundStyle(self.settingsSecondaryText)
                                        .frame(width: 36, alignment: .leading)
                                }
                            }

                            Divider().padding(.vertical, 4)

                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Overlay Size")
                                        .font(self.theme.typography.bodyStrong)
                                        .foregroundStyle(self.settingsTitleText)
                                    Text("How large the recording indicator appears")
                                        .font(self.theme.typography.bodySmall)
                                        .foregroundStyle(self.settingsSecondaryText)
                                }

                                Spacer()

                                Picker("", selection: self.$settings.overlaySize) {
                                    ForEach(SettingsStore.OverlaySize.allCases, id: \.self) { size in
                                        Text(size.displayName).tag(size)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 170, alignment: .trailing)
                            }

                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Live Preview")
                                        .font(self.theme.typography.bodyStrong)
                                        .foregroundStyle(self.settingsTitleText)
                                    Text("Show transcription text in the overlay while you speak")
                                        .font(self.theme.typography.bodySmall)
                                        .foregroundStyle(self.settingsSecondaryText)
                                }

                                Spacer()

                                Toggle("", isOn: self.$enableStreamingPreview)
                                    .labelsHidden()
                                    .onChange(of: self.enableStreamingPreview) { _, newValue in
                                        SettingsStore.shared.enableStreamingPreview = newValue
                                    }
                            }

                            Divider().padding(.vertical, 4)

                            // Bottom Offset
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Bottom Offset")
                                        .font(self.theme.typography.bodyStrong)
                                        .foregroundStyle(self.settingsTitleText)
                                    Text("Distance from bottom of screen")
                                        .font(self.theme.typography.bodySmall)
                                        .foregroundStyle(self.settingsSecondaryText)
                                }

                                Spacer()

                                HStack(spacing: 6) {
                                    Slider(value: self.$settings.overlayBottomOffset, in: 20...500)
                                        .frame(width: 110)
                                        .controlSize(.small)

                                    Text("\(Int(self.settings.overlayBottomOffset)) px")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(self.settingsSecondaryText)
                                        .frame(width: 54, alignment: .trailing)
                                }
                                .frame(width: 170, alignment: .trailing)
                            }

                            if self.asr.isRunning {
                                Text("Settings are disabled during active recording")
                                    .font(.caption)
                                    .foregroundStyle(self.settingsSecondaryText)
                                    .italic()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 4)
                            }
                    }
                }
                } // pageScope == .overlay

                if self.pageScope == .general {
                // Experimental
                self.settingsGroup(title: "Experimental", systemImage: "exclamationmark.triangle") {
                    VStack(alignment: .leading, spacing: 0) {
                        self.lowLatencyAudioCaptureToggle

                        if self.asr.isRunning {
                            Text("Settings are disabled during active recording")
                                .font(.caption)
                                .foregroundStyle(self.settingsSecondaryText)
                                .italic()
                                .padding(.top, 8)
                        }
                    }
                }
                } // pageScope == .general (Experimental)

                if self.pageScope == .debug {
                self.settingsGroup(title: "Debug", systemImage: "ladybug.fill") {
                    VStack(alignment: .leading, spacing: 0) {
                        self.settingsToggleRow(
                            title: "Show Debug Logs",
                            description: "File logs are always collected for diagnostics.",
                            isOn: Binding(
                                get: { SettingsStore.shared.enableDebugLogs },
                                set: { SettingsStore.shared.enableDebugLogs = $0 }
                            )
                        )

                        self.settingsRowDivider()

                        HStack {
                            Button {
                                let url = FileLogger.shared.currentLogFileURL()
                                if FileManager.default.fileExists(atPath: url.path) {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                } else {
                                    DebugLogger.shared.info("Log file not found at \(url.path)", source: "SettingsView")
                                }
                            } label: {
                                Label("Reveal Log File", systemImage: "doc.richtext")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)

                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                }
                } // pageScope == .debug
            }
            .vibePageContentColumn()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            Task { @MainActor in
                // Ensure the shared audio startup gate is scheduled. Safe to call repeatedly.
                await AudioStartupGate.shared.scheduleOpenAfterInitialUISettled()
                await AudioStartupGate.shared.waitUntilOpen()

                self.refreshDevices()

                // Sync input device selection after refresh
                if !self.inputDevices.isEmpty {
                    let inputValid = self.inputDevices.contains { $0.uid == self.selectedInputUID }
                    if !inputValid || self.selectedInputUID.isEmpty {
                        if let defaultUID = AudioDevice.getDefaultInputDevice()?.uid,
                           self.inputDevices.contains(where: { $0.uid == defaultUID })
                        {
                            self.selectedInputUID = defaultUID
                        } else {
                            self.selectedInputUID = self.inputDevices.first?.uid ?? ""
                        }
                    }
                }

                // Sync output device selection after refresh
                if !self.outputDevices.isEmpty {
                    let outputValid = self.outputDevices.contains { $0.uid == self.selectedOutputUID }
                    if !outputValid || self.selectedOutputUID.isEmpty {
                        if let prefUID = SettingsStore.shared.preferredOutputDeviceUID,
                           self.outputDevices.contains(where: { $0.uid == prefUID })
                        {
                            self.selectedOutputUID = prefUID
                        } else if let defaultUID = AudioDevice.getDefaultOutputDevice()?.uid,
                                  self.outputDevices.contains(where: { $0.uid == defaultUID })
                        {
                            self.selectedOutputUID = defaultUID
                        } else {
                            self.selectedOutputUID = self.outputDevices.first?.uid ?? ""
                        }
                    }
                }

                // CRITICAL FIX: Populate cached default device names after onAppear, not during view body evaluation.
                // This avoids the CoreAudio/SwiftUI AttributeGraph race condition that causes EXC_BAD_ACCESS.
                self.cachedDefaultInputName = AudioDevice.getDefaultInputDevice()?.name ?? ""
                self.cachedDefaultOutputName = AudioDevice.getDefaultOutputDevice()?.name ?? ""
                self.settings.refreshLaunchAtStartupStatus(clearError: true, logMismatch: false)
                self.refreshAudioHistoryUsage()
            }
        }
        .onChange(of: self.visualizerNoiseThreshold) { _, newValue in
            SettingsStore.shared.visualizerNoiseThreshold = newValue
        }
    }

    private func refreshAudioHistoryUsage() {
        self.audioHistoryUsageBytes = DictationAudioHistoryStore.shared.audioUsageBytes()
        self.audioHistoryBudgetText = Self.audioBudgetText(for: SettingsStore.shared.audioHistoryBudgetGB)
    }

    private func applyAudioHistoryBudget() {
        let normalized = self.audioHistoryBudgetText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value > 0 else {
            self.presentErrorAlert(title: "Invalid Budget", message: "Enter a positive number of GB.")
            self.refreshAudioHistoryUsage()
            return
        }

        let newBudget = max(0.1, value)
        let newBudgetBytes = DictationAudioHistoryStore.bytes(forGigabytes: newBudget)
        if self.audioHistoryUsageBytes > newBudgetBytes {
            let confirm = NSAlert()
            confirm.messageText = "Prune saved audio?"
            confirm.informativeText = """
            This budget is below current audio usage. VebeVoice will delete the oldest saved audio first and keep transcript history.
            """
            confirm.alertStyle = .warning
            confirm.addButton(withTitle: "Apply and Prune")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else {
                self.refreshAudioHistoryUsage()
                return
            }
        }

        SettingsStore.shared.audioHistoryBudgetGB = newBudget
        let pruned = TranscriptionHistoryStore.shared.pruneAudioToBudget()
        self.refreshAudioHistoryUsage()
        if pruned > 0 {
            self.presentInfoAlert(title: "Audio Pruned", message: "Deleted oldest saved audio from \(pruned) history entries.")
        }
    }

    private func deleteSavedAudio() {
        let confirm = NSAlert()
        confirm.messageText = "Delete saved audio?"
        confirm.informativeText = "This removes saved dictation audio only. Transcript history stays intact."
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Delete Audio")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let removed = TranscriptionHistoryStore.shared.deleteAllSavedAudio()
        self.refreshAudioHistoryUsage()
        self.presentInfoAlert(title: "Audio Deleted", message: "Removed audio from \(removed) history entries.")
    }

    private func exportAudioZip() {
        do {
            guard TranscriptionHistoryStore.shared.entries.contains(where: {
                DictationAudioHistoryStore.shared.audioFileExists(for: $0)
            }) else {
                throw DictationAudioHistoryError.noAudioEntries
            }

            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [.zip]
            panel.nameFieldStringValue = DictationAudioHistoryStore.shared.suggestedAudioExportFilename()

            guard panel.runModal() == .OK, let url = panel.url else { return }
            try DictationAudioHistoryStore.shared.exportAudioArchive(
                entries: TranscriptionHistoryStore.shared.entries,
                to: url
            )
            self.presentInfoAlert(title: "Audio Export Saved", message: "Saved your dictation audio export to:\n\(url.path)")
        } catch {
            self.presentErrorAlert(title: "Audio Export Failed", message: error.localizedDescription)
        }
    }

    private func presentInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Helper Views

    /// Flat settings group: optional section label above a card.
    @ViewBuilder
    private func settingsGroup<Content: View>(
        title: String?,
        systemImage: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title, !title.isEmpty {
                HStack(spacing: 6) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .textCase(.uppercase)
                        .tracking(0.6)
                }
                .foregroundStyle(self.settingsTertiaryText)
                .padding(.horizontal, 2)
            }

            ThemedCard(style: .standard, padding: 0) {
                content()
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
            }
        }
    }

    private func settingsRowDivider() -> some View {
        Divider()
            .overlay(self.theme.palette.separator.opacity(0.45))
            .padding(.vertical, 14)
    }

    private func settingsToggleRow(
        title: String,
        description: String,
        footnote: String? = nil,
        errorMessage: String? = nil,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(self.settingsTitleText)
                Text(description)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(self.settingsSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)

                if let footnote = footnote {
                    Text(footnote)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(self.settingsTertiaryText)
                        .padding(.top, 2)
                        .lineSpacing(2)
                }

                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(self.theme.palette.warning)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 16)

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .tint(self.theme.palette.accent)
                .labelsHidden()
        }
        .padding(.vertical, 8)
    }

    private func audioHistoryControls() -> some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Audio Storage")
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.settingsTitleText)
                    Text("Audio history: \(DictationAudioHistoryStore.formattedGigabytes(self.audioHistoryUsageBytes)) / \(Self.audioBudgetText(for: SettingsStore.shared.audioHistoryBudgetGB)) GB Budget")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.settingsSecondaryText)

                    ProgressView(value: self.audioHistoryUsageFraction())
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 220)
                }

                Spacer(minLength: 16)

                HStack(spacing: 8) {
                    Text("Budget")
                        .font(.caption)
                        .foregroundStyle(self.settingsSecondaryText)

                    TextField("4", text: self.$audioHistoryBudgetText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 58)

                    Text("GB")
                        .font(.caption)
                        .foregroundStyle(self.settingsSecondaryText)

                    Button("Apply") {
                        self.applyAudioHistoryBudget()
                    }
                    .controlSize(.small)
                }
            }

            Divider().opacity(0.2)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Export Audio")
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.settingsTitleText)
                    Text("ZIP with manifest.jsonl and WAV audio.")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.settingsSecondaryText)
                }

                Spacer(minLength: 16)

                Button {
                    self.exportAudioZip()
                } label: {
                    Label("Export ZIP", systemImage: "square.and.arrow.up")
                }
                .controlSize(.small)

                Button(role: .destructive) {
                    self.deleteSavedAudio()
                } label: {
                    Label("Delete Audio", systemImage: "trash")
                }
                .controlSize(.small)
                .disabled(self.audioHistoryUsageBytes <= 0)
            }
        }
    }

    private static func audioBudgetText(for value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }

    private func audioHistoryUsageFraction() -> Double {
        let budget = SettingsStore.shared.audioHistoryBudgetBytes
        guard budget > 0 else { return 0 }
        return min(1, Double(self.audioHistoryUsageBytes) / Double(budget))
    }

    private func optionToggleRow(
        title: String,
        description: String,
        isOn: Binding<Bool>,
        allowsDescriptionWrapping: Bool = false
    ) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(self.theme.typography.bodyStrong)
                    .foregroundStyle(self.settingsTitleText)
                Text(description)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.settingsSecondaryText)
                    .fixedSize(horizontal: false, vertical: allowsDescriptionWrapping)
            }
            .frame(maxWidth: allowsDescriptionWrapping ? .infinity : nil, alignment: .leading)

            if !allowsDescriptionWrapping {
                Spacer()
            }

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .tint(self.theme.palette.accent)
                .labelsHidden()
        }
    }

    private func instructionsBox(
        title: String,
        steps: [String],
        warningStyle: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(warningStyle ? self.theme.palette.warning : self.theme.palette.accent)
                    .font(.caption)
                Text(title)
                    .font(self.theme.typography.bodySmallStrong)
                    .foregroundStyle(self.settingsTitleText)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.caption)
                            .foregroundStyle(warningStyle ? self.theme.palette.warning : self.theme.palette.accent)
                            .fontWeight(.semibold)
                            .frame(width: 16, alignment: .trailing)
                        Text(.init(step))
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill((warningStyle ? self.theme.palette.warning : self.theme.palette.accent).opacity(0.12))
        )
    }

    @ViewBuilder
    private func primaryDictationShortcutsList() -> some View {
        let addTarget = ShortcutRecordingTarget.primaryDictation(.add)
        let isAdding = self.isRecording(addTarget)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(self.settingsSecondaryText)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Primary Dictation Shortcuts")
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.settingsTitleText)
                    Text("Use any keyboard shortcut, auxiliary mouse button, or modified click.")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.settingsSecondaryText)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    if isAdding {
                        self.shortcutRecordingMessage = nil
                        self.activeShortcutRecordingTarget = nil
                    } else {
                        DebugLogger.shared.debug("Starting to record new primary dictation shortcut", source: "SettingsView")
                        self.shortcutRecordingMessage = nil
                        self.activeShortcutRecordingTarget = addTarget
                    }
                } label: {
                    Label(isAdding ? "Cancel" : "Add shortcut", systemImage: isAdding ? "xmark" : "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!isAdding && self.isRecordingAnyShortcut)
            }

            ForEach(Array(self.primaryDictationShortcuts.enumerated()), id: \.offset) { index, shortcut in
                self.primaryDictationShortcutRow(shortcut: shortcut, index: index)
            }

            if isAdding {
                self.primaryDictationShortcutCaptureStatus(for: addTarget)
            }
        }
    }

    @ViewBuilder
    private func primaryDictationShortcutRow(shortcut: HotkeyShortcut, index: Int) -> some View {
        let target = ShortcutRecordingTarget.primaryDictation(.replace(index))
        let isRecording = self.isRecording(target)

        HStack(spacing: 10) {
            Color.clear
                .frame(width: 20)

            if isRecording {
                self.shortcutCapturePill()
            } else {
                self.shortcutDisplayPill(shortcut.displayString)
            }

            Button(isRecording ? "Cancel" : "Change") {
                if isRecording {
                    self.shortcutRecordingMessage = nil
                    self.activeShortcutRecordingTarget = nil
                } else {
                    DebugLogger.shared.debug("Starting to record replacement primary dictation shortcut", source: "SettingsView")
                    self.shortcutRecordingMessage = nil
                    self.activeShortcutRecordingTarget = target
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!isRecording && self.isRecordingAnyShortcut)

            Button("Remove") {
                guard self.primaryDictationShortcuts.count > 1,
                      self.primaryDictationShortcuts.indices.contains(index)
                else { return }
                self.primaryDictationShortcuts.remove(at: index)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(self.primaryDictationShortcuts.count <= 1 || self.isRecordingAnyShortcut)

            if isRecording,
               let recordingMessage = self.shortcutRecordingMessage,
               !recordingMessage.isEmpty
            {
                Text(recordingMessage)
                    .font(.caption)
                    .foregroundStyle(self.theme.palette.warning)
            }
        }
    }

    private func primaryDictationShortcutCaptureStatus(for target: ShortcutRecordingTarget) -> some View {
        HStack(spacing: 10) {
            Color.clear
                .frame(width: 20)

            self.shortcutCapturePill()

            if self.isRecording(target),
               let recordingMessage = self.shortcutRecordingMessage,
               !recordingMessage.isEmpty
            {
                Text(recordingMessage)
                    .font(.caption)
                    .foregroundStyle(self.theme.palette.warning)
            }
        }
    }

    private func shortcutCapturePill() -> some View {
        Text("Press shortcut...")
            .font(.caption.weight(.medium))
            .foregroundStyle(AppTheme.VibeBrand.amber)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(AppTheme.VibeBrand.amber.opacity(0.2))
            )
    }

    private func shortcutDisplayPill(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospaced().weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(.primary.opacity(0.15), lineWidth: 1)
                    )
            )
    }

    @ViewBuilder
    private func shortcutRow(
        content: ShortcutRowContent,
        shortcut: HotkeyShortcut?,
        isRecording: Bool,
        isAnyRecordingActive: Bool,
        recordingMessage: String? = nil,
        isEnabled: Binding<Bool>? = nil,
        requiresShortcutToEnable: Bool = false,
        onChangePressed: @escaping () -> Void,
        onRemovePressed: (() -> Void)? = nil
    ) -> some View {
        let enabledValue = isEnabled?.wrappedValue ?? true
        let hasShortcut = shortcut != nil
        let enableToggleDisabled = isAnyRecordingActive || (requiresShortcutToEnable && !hasShortcut)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: content.icon)
                    .foregroundStyle(content.iconColor)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(content.title)
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.settingsTitleText)
                    Text(content.description)
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.settingsSecondaryText)
                        .lineLimit(1)
                }

                Spacer()

                if let isEnabled {
                    Toggle("", isOn: isEnabled)
                        .toggleStyle(.switch)
                        .tint(self.theme.palette.accent)
                        .labelsHidden()
                        .disabled(enableToggleDisabled)
                }
            }

            HStack(spacing: 10) {
                Color.clear
                    .frame(width: 20)

                if isRecording {
                    self.shortcutCapturePill()
                } else {
                    self.shortcutDisplayPill(shortcut?.displayString ?? "Not set")
                }

                Button(isRecording ? "Cancel" : "Change") {
                    if isRecording {
                        self.shortcutRecordingMessage = nil
                        self.activeShortcutRecordingTarget = nil
                    } else {
                        onChangePressed()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!isRecording && (isAnyRecordingActive || (!enabledValue && hasShortcut)))

                if let onRemovePressed {
                    Button("Remove") {
                        onRemovePressed()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!hasShortcut || isAnyRecordingActive)
                }

                if isRecording, let recordingMessage, !recordingMessage.isEmpty {
                    Text(recordingMessage)
                        .font(.caption)
                        .foregroundStyle(self.theme.palette.warning)
                }
            }
        }
        .opacity(enabledValue ? 1 : 0.7)
    }
}

private extension SettingsView {
    var microphoneModeInfo: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(self.settingsSecondaryText)
                .font(self.theme.typography.bodyStrong)
            Text(
                self.microphoneSelectionMode == .system
                    ? "VebeVoice follows the macOS default microphone."
                    : "VebeVoice keeps your preferred microphone selected while it is available."
            )
            .font(self.theme.typography.bodySmall)
            .foregroundStyle(self.settingsSecondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    var microphoneModeToggle: some View {
        Toggle(
            "Use macOS default microphone",
            isOn: Binding(
                get: { self.microphoneSelectionMode == .system },
                set: { self.updateMicrophoneSelectionMode(useSystemDefault: $0) }
            )
        )
        .toggleStyle(.switch)
        .font(self.theme.typography.bodyStrong)
        .foregroundStyle(self.settingsTitleText)
        .disabled(self.asr.isRunning)
    }

    func updateMicrophoneSelectionMode(useSystemDefault: Bool) {
        let nextMode: SettingsStore.MicrophoneSelectionMode = useSystemDefault ? .system : .manual
        let currentSystemInputUID = AudioDevice.getDefaultInputDevice()?.uid
        let availableInputUIDs = Set(self.inputDevices.map(\.uid))
        let restoredSystemInputUID = SettingsStore.shared.setMicrophoneSelectionMode(
            nextMode,
            currentSystemInputUID: currentSystemInputUID,
            availableInputUIDs: availableInputUIDs
        )
        self.microphoneSelectionMode = nextMode

        if nextMode == .manual {
            if self.selectedInputUID.isEmpty,
               let defaultUID = currentSystemInputUID
            {
                self.selectedInputUID = defaultUID
                SettingsStore.shared.recordInputDeviceSelection(defaultUID)
            } else {
                SettingsStore.shared.recordInputDeviceSelection(self.selectedInputUID)
            }
        } else if let restoredSystemInputUID {
            self.selectedInputUID = restoredSystemInputUID
            _ = AudioDevice.setDefaultInputDevice(uid: restoredSystemInputUID)
        }
    }
}

private final class SettingsPersistentScroller: NSScroller {
    override static var isCompatibleWithOverlayScrollers: Bool {
        false
    }
}

private struct SettingsPersistentScrollView<Content: View>: NSViewRepresentable {
    private let theme: AppTheme
    private let colorScheme: ColorScheme
    private let content: Content

    init(theme: AppTheme, colorScheme: ColorScheme, @ViewBuilder content: () -> Content) {
        self.theme = theme
        self.colorScheme = colorScheme
        self.content = content()
    }

    private var hostedContent: AnyView {
        AnyView(
            self.content
                .appTheme(self.theme)
                .environment(\.colorScheme, self.colorScheme)
        )
    }

    func makeNSView(context _: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        scrollView.verticalScroller = SettingsPersistentScroller()
        scrollView.verticalScroller?.isHidden = false
        scrollView.verticalScroller?.alphaValue = 1
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none

        let hostingView = NSHostingView(rootView: self.hostedContent)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hostingView.setContentHuggingPriority(.required, for: .vertical)

        scrollView.documentView = hostingView
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            hostingView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context _: Context) {
        (scrollView.documentView as? NSHostingView<AnyView>)?.rootView = self.hostedContent
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        if !(scrollView.verticalScroller is SettingsPersistentScroller) {
            scrollView.verticalScroller = SettingsPersistentScroller()
        }
        scrollView.verticalScroller?.isHidden = false
        scrollView.verticalScroller?.alphaValue = 1
    }
}

// MARK: - Filler Words Editor

struct FillerWordsEditor: View {
    @State private var fillerWords: [String] = SettingsStore.shared.fillerWords
    @State private var newWord: String = ""
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Filler words to remove:")
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(.secondary)

            // Word chips
            FlowLayout(spacing: 6) {
                ForEach(self.fillerWords, id: \.self) { word in
                    HStack(spacing: 4) {
                        Text(word)
                            .font(.caption)
                        Button {
                            self.removeWord(word)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.quaternary)
                    )
                }
            }

            // Add new word
            HStack(spacing: 8) {
                TextField("Add word", text: self.$newWord)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .onSubmit { self.addWord() }

                Button("Add") { self.addWord() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(self.newWord.trimmingCharacters(in: .whitespaces).isEmpty)

                Spacer()

                Button("Reset") {
                    self.fillerWords = SettingsStore.defaultFillerWords
                    SettingsStore.shared.fillerWords = self.fillerWords
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func addWord() {
        let word = self.newWord.trimmingCharacters(in: .whitespaces).lowercased()
        guard !word.isEmpty, !self.fillerWords.contains(word) else { return }
        self.fillerWords.append(word)
        SettingsStore.shared.fillerWords = self.fillerWords
        self.newWord = ""
    }

    private func removeWord(_ word: String) {
        self.fillerWords.removeAll { $0 == word }
        SettingsStore.shared.fillerWords = self.fillerWords
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    struct Cache {
        var sizes: [CGSize] = []
        var positions: [CGPoint] = []
        var containerSize: CGSize = .zero
        var lastWidth: CGFloat = 0
    }

    var spacing: CGFloat = 8

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: Array(repeating: .zero, count: subviews.count))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        self.arrangeSubviews(proposal: proposal, subviews: subviews, cache: &cache)
        return cache.containerSize
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        self.arrangeSubviews(proposal: proposal, subviews: subviews, cache: &cache)
        for (index, position) in cache.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrangeSubviews(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        let proposedWidth = proposal.width ?? 0
        let maxWidth = proposedWidth > 0 ? proposedWidth : 260
        let needsLayout = cache.positions.count != subviews.count || cache.lastWidth != maxWidth

        if needsLayout {
            cache.positions = []
            cache.positions.reserveCapacity(subviews.count)
            cache.sizes = Array(repeating: .zero, count: subviews.count)
        }

        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for index in subviews.indices {
            let size: CGSize
            if needsLayout {
                size = subviews[index].sizeThatFits(.unspecified)
                cache.sizes[index] = size
            } else {
                size = cache.sizes[index]
            }

            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + self.spacing
                rowHeight = 0
            }
            if needsLayout {
                cache.positions.append(CGPoint(x: x, y: y))
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + self.spacing
        }

        cache.containerSize = CGSize(width: maxWidth, height: y + rowHeight)
        cache.lastWidth = maxWidth
    }
}

private extension SettingsView {
    var lowLatencyAudioCaptureToggle: some View {
        Group {
            self.settingsToggleRow(
                title: "Faster Recording Start",
                description: "VebeVoice starts listening sooner, so your first word is less likely to be missed.",
                footnote: "If your microphone does not work correctly, turn this off.",
                isOn: Binding(
                    get: { self.settings.experimentalDirectAudioCaptureEnabled },
                    set: { enabled in
                        self.settings.experimentalDirectAudioCaptureEnabled = enabled
                        if enabled {
                            self.settings.directAudioCaptureConsecutiveFailures = 0
                        }
                        self.asr.refreshAudioCaptureBackendPreference()
                    }
                )
            )
            .disabled(self.asr.isRunning)

            Divider().padding(.vertical, 8)
        }
    }
}
