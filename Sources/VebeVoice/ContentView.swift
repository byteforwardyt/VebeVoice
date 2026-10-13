//
//  ContentView.swift
//  VebeVoice
//
//  Created by Barathwaj Anandan on 7/30/25.
//

import AppKit
import AVFoundation
import Combine
import CoreAudio
import CoreGraphics
import Security
import SwiftUI

// MARK: - Sidebar Item Enum

/// Primary destinations in the main window sidebar / navigation stack.
enum SidebarItem: Hashable {
    case welcome
    case voiceEngine
    case preferences
    /// Keyboard shortcuts, hotkey mode, and Accessibility — promoted out of mega-Settings.
    case keyboardShortcuts
    /// Overlay size/position/preview controls — promoted out of mega-Settings.
    case overlaySettings
    case meetingTools
    case customDictionary
    case stats
    case history
    /// In-app dictation sandbox (was embedded on Start).
    case testPlayground
    /// Diagnostics / log controls (was buried under General).
    case debug
}

/// Source of truth for sidebar composition (sections + destinations).
/// Tests and the sidebar UI both read this — keep them in sync by only editing here.
enum SidebarNavigationCatalog {
    struct Entry: Hashable {
        let item: SidebarItem
        let title: String
        let systemImage: String
    }

    struct Section: Hashable {
        let id: String
        let title: String
        let entries: [Entry]
    }

    /// Ordered sidebar sections — one-word destination labels for scannability.
    static let sections: [Section] = [
        Section(
            id: "setup",
            title: "Setup",
            entries: [
                Entry(item: .preferences, title: "General", systemImage: "gearshape.fill"),
                Entry(item: .keyboardShortcuts, title: "Shortcuts", systemImage: "keyboard"),
                Entry(item: .overlaySettings, title: "Overlay", systemImage: "rectangle.bottomhalf.inset.filled"),
                Entry(item: .voiceEngine, title: "Engine", systemImage: "waveform"),
                Entry(item: .customDictionary, title: "Dictionary", systemImage: "text.book.closed.fill"),
            ]
        ),
        Section(
            id: "tools",
            title: "Tools",
            entries: [
                Entry(item: .meetingTools, title: "Transcription", systemImage: "doc.text.fill"),
                Entry(item: .testPlayground, title: "Playground", systemImage: "text.bubble.fill"),
            ]
        ),
        Section(
            id: "activity",
            title: "Activity",
            entries: [
                Entry(item: .history, title: "History", systemImage: "clock.arrow.circlepath"),
                Entry(item: .stats, title: "Stats", systemImage: "chart.bar.fill"),
            ]
        ),
        Section(
            id: "help",
            title: "Help",
            entries: [
                Entry(item: .welcome, title: "Start", systemImage: "house.fill"),
                Entry(item: .debug, title: "Debug", systemImage: "ladybug.fill"),
            ]
        ),
    ]

}

/// Which Settings groups a focused Settings page shows.
enum SettingsPageScope: String, Hashable, CaseIterable {
    case general
    case keyboardShortcuts
    case overlay
    case debug
}

enum PrimaryDictationShortcutEdit: Hashable {
    case add
    case replace(Int)

    var replacementIndex: Int? {
        if case let .replace(index) = self { return index }
        return nil
    }
}

enum ShortcutRecordingTarget: Hashable {
    case primaryDictation(PrimaryDictationShortcutEdit)
    case secondaryDictation
    case cancel
    case pasteLast

    var title: String {
        switch self {
        case .primaryDictation:
            return "Primary Dictation Shortcut"
        case .secondaryDictation:
            return "Secondary Dictation Shortcut"
        case .cancel:
            return "Cancel Recording"
        case .pasteLast:
            return "Paste Last Transcription"
        }
    }

    var enablesFeatureOnAssignment: Bool {
        switch self {
        case .secondaryDictation, .pasteLast:
            return true
        case .primaryDictation, .cancel:
            return false
        }
    }

    var allowsMouseShortcut: Bool {
        switch self {
        case .primaryDictation, .pasteLast:
            return true
        case .secondaryDictation, .cancel:
            return false
        }
    }

    var isPrimaryDictation: Bool {
        if case .primaryDictation = self { return true }
        return false
    }

    var primaryDictationReplacementIndex: Int? {
        if case let .primaryDictation(edit) = self {
            return edit.replacementIndex
        }
        return nil
    }
}

// swiftlint:disable type_body_length file_length
struct ContentView: View {
    private enum ActiveRecordingMode: String {
        case none
        case dictate
        case promptMode
    }

    private enum DictationOutputRoute: String {
        case normal
        case onboardingSandbox
    }

    @EnvironmentObject private var appServices: AppServices
    @EnvironmentObject private var menuBarManager: MenuBarManager
    @ObservedObject private var settings = SettingsStore.shared

    /// Computed properties to access shared services from AppServices container
    /// This maintains backward compatibility with the existing code while
    /// removing the duplicate service instances that cause startup crashes.
    private var asr: ASRService {
        self.appServices.asr
    }

    private var audioObserver: AudioHardwareObserver {
        self.appServices.audioObserver
    }

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var hotkeyManager: GlobalHotkeyManager? = nil
    @State private var hotkeyManagerInitialized: Bool = false

    /// Toolbar icons stay light-on-dark / dark-on-light with brand purple chrome.
    private var toolbarColorScheme: ColorScheme {
        self.colorScheme == .dark ? .dark : .light
    }

    @State private var appear = false
    @State private var accessibilityEnabled = false
    @State private var primaryDictationShortcuts: [HotkeyShortcut] = SettingsStore.shared.primaryDictationShortcuts
    @State private var promptModeHotkeyShortcut: HotkeyShortcut = SettingsStore.shared.promptModeHotkeyShortcut
    @State private var cancelRecordingHotkeyShortcut: HotkeyShortcut = SettingsStore.shared.cancelRecordingHotkeyShortcut
    @State private var pasteLastTranscriptionHotkeyShortcut: HotkeyShortcut? = SettingsStore.shared.pasteLastTranscriptionHotkeyShortcut
    @State private var isPasteLastTranscriptionShortcutEnabled: Bool = SettingsStore.shared.pasteLastTranscriptionShortcutEnabled
    @State private var isPromptModeShortcutEnabled: Bool = SettingsStore.shared.promptModeShortcutEnabled
    @State private var activeRecordingMode: ActiveRecordingMode = .none
    @State private var activeShortcutRecordingTarget: ShortcutRecordingTarget? = nil
    @State private var currentRecordingModifierKeyCodes: Set<UInt16> = []
    @State private var pendingModifierKeyCodes: Set<UInt16> = []
    @State private var pendingModifierFlags: NSEvent.ModifierFlags = []
    @State private var pendingModifierKeyCode: UInt16?
    @State private var pendingModifierOnly = false
    @State private var shortcutRecordingMessage: String? = nil
    @State private var shortcutCaptureMonitor: Any?
    @FocusState private var isTranscriptionFocused: Bool

    @State private var selectedSidebarItem: SidebarItem?
    @State private var previousSidebarItem: SidebarItem? = nil // Track previous for mode transitions
    @State private var playgroundUsed: Bool = SettingsStore.shared.playgroundUsed
    @State private var recordingAppInfo: (name: String, bundleId: String, windowTitle: String)? = nil
    @State private var recordingPrecedingText: String = ""

    // Audio Settings Tab State
    @State private var visualizerNoiseThreshold: Double = SettingsStore.shared.visualizerNoiseThreshold
    @State private var inputDevices: [AudioDevice.Device] = []
    @State private var outputDevices: [AudioDevice.Device] = []
    @State private var selectedInputUID: String = AudioDevice.getDefaultInputDevice()?.uid ?? ""
    @State private var selectedOutputUID: String = SettingsStore.shared.preferredOutputDeviceUID ?? ""
    @State private var microphoneSelectionMode: SettingsStore.MicrophoneSelectionMode = SettingsStore.shared.microphoneSelectionMode

    @State private var hotkeyMode: HotkeyActivationMode = SettingsStore.shared.hotkeyMode
    @State private var enableStreamingPreview: Bool = SettingsStore.shared.enableStreamingPreview
    @State private var copyToClipboard: Bool = SettingsStore.shared.copyTranscriptionToClipboard

    // Preferences Tab State
    @State private var showRestartPrompt: Bool = false
    @State private var didOpenAccessibilityPane: Bool = false
    private let accessibilityRestartFlagKey = "VebeVoice_AccessibilityRestartPending"
    private let hasAutoRestartedForAccessibilityKey = "VebeVoice_HasAutoRestartedForAccessibility"
    @State private var accessibilityPollingTask: Task<Void, Never>?
    @State private var accessibilityGuidePanel: NSPanel?
    @State private var accessibilityGuideMonitorTask: Task<Void, Never>?
    @State private var accessibilityGuideRequestID: UUID?
    @State private var prewarmDictationTask: Task<Void, Never>?
    @State private var overlayLifecycleID: UInt64 = 0

    private var isRecordingAnyShortcutCapture: Bool {
        self.activeShortcutRecordingTarget != nil
    }

    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        let layout = AnyView(
            Group {
                if self.settings.shouldShowOnboarding {
                    self.onboardingOnlyView
                } else {
                    NavigationSplitView(columnVisibility: self.$columnVisibility) {
                        self.sidebarView
                            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
                            // Strip system chrome — brand + collapser live in the sidebar itself.
                            .toolbar(removing: .sidebarToggle)
                            .toolbar(removing: .title)
                    } detail: {
                        self.detailView
                            .toolbar(removing: .sidebarToggle)
                            .toolbar(removing: .title)
                    }
                    .navigationSplitViewStyle(.balanced)
                    .toolbar(removing: .sidebarToggle)
                    .toolbar(removing: .title)
                }
            }
        )

        let nav = layout.onChange(of: self.menuBarManager.requestedNavigationDestination) { _, destination in
            self.handleMenuBarNavigation(destination)
        }
        let sized = nav.vibeWindowSizing(self.windowSizing)

        let observed = self.applyShortcutStateChanges(to: sized)

        return observed
            .tint(self.theme.palette.accent)
            .background(self.theme.palette.windowBackground)
            // Solid brand toolbar — without this, NavigationSplitView keeps the
            // default system gray titlebar material over purple page chrome.
            .toolbarBackground(self.theme.palette.toolbarBackground, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
            .toolbarColorScheme(self.toolbarColorScheme, for: .windowToolbar)
            .vibeWindowChrome(
                background: self.theme.palette.toolbarBackground,
                isDark: self.colorScheme == .dark
            )
            .onAppear {
                // Keep the whole app on brand purple accents (legacy non-purple accents remapped).
                let current = self.settings.accentColorOption
                if ![.purple, .void, .lilac, .pink, .blue, .mint, .gold, .amber].contains(current) {
                    self.settings.accentColorOption = .void
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                self.refreshAccessibilityPermissionState()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openCustomDictionaryFromVoiceEngine)) { _ in
                self.selectedSidebarItem = .customDictionary
            }
            .onReceive(NotificationCenter.default.publisher(for: .appNavigationRequested)) { _ in
                self.handlePendingAppNavigation()
            }
            .toolbar {
                if !self.settings.shouldShowOnboarding, self.columnVisibility == .detailOnly {
                    // Sidebar chrome (brand + stats/theme/bug) is hidden when collapsed —
                    // only re-surface the expand control in the window toolbar.
                    ToolbarItem(placement: .navigation) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                self.columnVisibility = .all
                            }
                        } label: {
                            Image(systemName: "sidebar.left")
                        }
                        .help("Show Sidebar")
                        .accessibilityLabel("Show Sidebar")
                    }
                }
            }
            .toolbar(removing: .sidebarToggle)
            .overlay(alignment: .center) {}
            .alert(
                self.asr.errorTitle,
                isPresented: Binding(
                    get: { self.asr.showError },
                    set: { self.asr.showError = $0 }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(self.asr.errorMessage)
            }
            .onChange(of: self.audioObserver.changeTick) { _, _ in
                // Hardware change detected → refresh device lists
                self.refreshDevices()

                switch SettingsStore.shared.microphoneSelectionMode {
                case .system:
                    if let sysIn = AudioDevice.getDefaultInputDevice()?.uid {
                        self.selectedInputUID = sysIn
                    }
                case .manual:
                    // The refreshed device list drives the displayed selection.
                    break
                }

                if let sysOut = AudioDevice.getDefaultOutputDevice()?.uid {
                    self.selectedOutputUID = sysOut
                }
            }
            .onDisappear {
                Task { await self.asr.stopWithoutTranscription() }
                self.cancelPrewarmDictationIfNeeded()
                // Note: Overlay lifecycle is now managed by MenuBarManager
                // Note: NotchContentState handlers capture self (a struct value copy) and are
                // intentionally kept alive so the overlay remains fully functional when the
                // settings window is closed. No retain cycle risk since ContentView is a value type.

                // Stop accessibility polling
                self.finishAccessibilityPermissionFlow()
                self.removeShortcutCaptureMonitor()
            }
            .onChange(of: self.primaryDictationShortcuts) { _, newValue in
                SettingsStore.shared.primaryDictationShortcuts = newValue
                let storedShortcuts = SettingsStore.shared.primaryDictationShortcuts
                if storedShortcuts != newValue {
                    self.primaryDictationShortcuts = storedShortcuts
                    return
                }

                let display = storedShortcuts.map(\.displayString).joined(separator: ", ")
                DebugLogger.shared.debug("Primary dictation shortcuts changed to \(display)", source: "ContentView")
                self.hotkeyManager?.updatePrimaryShortcuts(storedShortcuts)

                // Update initialization status after shortcut change
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.hotkeyManagerInitialized = self.hotkeyManager?.validateEventTapHealth() ?? false
                    DebugLogger.shared.debug(
                        "Hotkey manager initialized: \(self.hotkeyManagerInitialized)",
                        source: "ContentView"
                    )
                }
            }
            .onChange(of: self.selectedSidebarItem) { _, newValue in
                self.handleModeTransition(from: self.previousSidebarItem, to: newValue)
                self.previousSidebarItem = newValue
            }
    }

    private func applyShortcutStateChanges<Content: View>(to view: Content) -> some View {
        view
            .onAppear {
                self.handleContentAppear()
            }
            .onChange(of: self.accessibilityEnabled) { _, enabled in
                if enabled {
                    self.finishAccessibilityPermissionFlow()
                }

                if enabled && self.hotkeyManager != nil && !self.hotkeyManagerInitialized {
                    DebugLogger.shared.debug("Accessibility enabled, reinitializing hotkey manager", source: "ContentView")
                    self.hotkeyManager?.reinitialize()
                }
            }
            .onChange(of: self.activeShortcutRecordingTarget) { _, _ in
                self.hotkeyManager?.resetModifierOnlyShortcutTracking()
            }
            .onChange(of: self.isPromptModeShortcutEnabled) { newValue in
                self.handlePromptShortcutEnabledChange(newValue)
            }
            .onChange(of: self.pasteLastTranscriptionHotkeyShortcut) { _, newValue in
                // The hotkey manager reads this value live from SettingsStore, so persisting is enough.
                SettingsStore.shared.pasteLastTranscriptionHotkeyShortcut = newValue
            }
            .onChange(of: self.isPasteLastTranscriptionShortcutEnabled) { newValue in
                self.handlePasteLastTranscriptionShortcutEnabledChange(newValue)
            }
    }

    private func handlePasteLastTranscriptionShortcutEnabledChange(_ isEnabled: Bool) {
        SettingsStore.shared.pasteLastTranscriptionShortcutEnabled = isEnabled
        if !isEnabled, self.activeShortcutRecordingTarget == .pasteLast {
            self.clearShortcutRecordingMode()
        }
    }

    private func handlePromptShortcutEnabledChange(_ isEnabled: Bool) {
        SettingsStore.shared.promptModeShortcutEnabled = isEnabled
        self.hotkeyManager?.updatePromptModeShortcutEnabled(isEnabled)

        if !isEnabled {
            if self.activeShortcutRecordingTarget == .secondaryDictation {
                self.clearShortcutRecordingMode()
            }

            if self.activeRecordingMode == .promptMode {
                if self.asr.isRunning {
                    Task { await self.asr.stopWithoutTranscription() }
                }
                self.cancelPrewarmDictationIfNeeded()
                self.clearActiveRecordingMode()
                self.menuBarManager.setOverlayMode(.dictation)
            }
        }
    }

    private func handleContentAppear() {
        self.appear = true
        self.refreshAccessibilityPermissionState()

        self.handleMenuBarNavigation(self.menuBarManager.requestedNavigationDestination)
        if UserDefaults.standard.bool(forKey: self.accessibilityRestartFlagKey) {
            UserDefaults.standard.set(false, forKey: self.accessibilityRestartFlagKey)
            self.showRestartPrompt = false
        }

        if self.accessibilityEnabled {
            self.finishAccessibilityPermissionFlow()
        }

        if self.selectedSidebarItem == nil {
            let isOnboarded = self.asr.isAsrReady || self.asr.modelsExistOnDisk
            self.selectedSidebarItem = isOnboarded ? .preferences : .welcome
        }
        self.handlePendingAppNavigation()

        if !self.accessibilityEnabled {
            UserDefaults.standard.set(false, forKey: self.hasAutoRestartedForAccessibilityKey)
        }

        self.menuBarManager.initializeMenuBar()
        self.scheduleDelayedAudioInitialization()
        self.startAccessibilityPolling()
        self.initializeHotkeyManagerIfNeeded()

        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await self.preloadASRModel()
        }

        self.installShortcutCaptureMonitor()
    }

    private func scheduleDelayedAudioInitialization() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            DebugLogger.shared.info("🚦 Startup delay complete, signaling UI ready...", source: "ContentView")
            self.appServices.signalUIReady()

            DebugLogger.shared.info("🔊 Starting delayed audio initialization...", source: "ContentView")
            self.audioObserver.startObserving()
            self.asr.initialize()
            self.menuBarManager.configure(asrService: self.appServices.asr)
            self.refreshDevices()

            switch SettingsStore.shared.microphoneSelectionMode {
            case .system:
                if let defaultUID = AudioDevice.getDefaultInputDevice()?.uid {
                    self.selectedInputUID = defaultUID
                }
            case .manual:
                if let preferredUID = SettingsStore.shared.preferredInputDeviceUID, !preferredUID.isEmpty {
                    self.selectedInputUID = preferredUID
                } else if let defaultUID = AudioDevice.getDefaultInputDevice()?.uid {
                    self.selectedInputUID = defaultUID
                    SettingsStore.shared.preferredInputDeviceUID = defaultUID
                }
            }

            if self.selectedOutputUID.isEmpty, let defOut = AudioDevice.getDefaultOutputDevice()?.uid {
                self.selectedOutputUID = defOut
            }

            if let prefOut = SettingsStore.shared.preferredOutputDeviceUID,
               !prefOut.isEmpty,
               outputDevices.first(where: { $0.uid == prefOut }) != nil
            {
                self.selectedOutputUID = prefOut
            }

            DebugLogger.shared.info("✅ Audio subsystems initialized", source: "ContentView")
        }
    }

    private func installShortcutCaptureMonitor() {
        self.removeShortcutCaptureMonitor()
        self.shortcutCaptureMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            self.handleShortcutCaptureEvent(event)
        }
    }

    private func removeShortcutCaptureMonitor() {
        guard let monitor = self.shortcutCaptureMonitor else { return }
        NSEvent.removeMonitor(monitor)
        self.shortcutCaptureMonitor = nil
    }

    private func handleShortcutCaptureEvent(_ event: NSEvent) -> NSEvent? {
        let eventModifiers = event.modifierFlags.intersection([.function, .command, .option, .control, .shift])
        let isRecordingAnyShortcut = self.isRecordingAnyShortcutCapture
        let recordingTarget = self.activeShortcutRecordingTarget

        if event.type == .keyDown {
            return self.handleShortcutKeyDownEvent(event, modifiers: eventModifiers, isRecordingAnyShortcut: isRecordingAnyShortcut, recordingTarget: recordingTarget)
        } else if event.type == .flagsChanged {
            return self.handleShortcutFlagsChangedEvent(event, modifiers: eventModifiers, isRecordingAnyShortcut: isRecordingAnyShortcut, recordingTarget: recordingTarget)
        } else if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
            return self.handleShortcutMouseDownEvent(event, modifiers: eventModifiers, isRecordingAnyShortcut: isRecordingAnyShortcut, recordingTarget: recordingTarget)
        }

        return event
    }

    private func handleShortcutKeyDownEvent(
        _ event: NSEvent,
        modifiers eventModifiers: NSEvent.ModifierFlags,
        isRecordingAnyShortcut: Bool,
        recordingTarget: ShortcutRecordingTarget?
    ) -> NSEvent? {
        guard isRecordingAnyShortcut else {
            if self.cancelRecordingHotkeyShortcut.matches(keyCode: event.keyCode, modifiers: eventModifiers),
               self.handleCancelShortcut()
            {
                return nil
            }
            self.shortcutRecordingMessage = nil
            self.resetPendingShortcutState()
            return event
        }

        let keyCode = event.keyCode
        if keyCode == 53, recordingTarget != .cancel {
            DebugLogger.shared.debug("NSEvent monitor: Escape pressed, cancelling shortcut recording", source: "ContentView")
            self.clearShortcutRecordingMode()
            return nil
        }

        let newShortcut = HotkeyShortcut(keyCode: keyCode, modifierFlags: self.pendingModifierFlags.union(eventModifiers))
        DebugLogger.shared.debug("NSEvent monitor: Recording new shortcut: \(newShortcut.displayString)", source: "ContentView")

        if let recordingTarget,
           let conflictMessage = self.shortcutConflictMessage(for: newShortcut, target: recordingTarget)
        {
            self.shortcutRecordingMessage = conflictMessage
            self.resetPendingShortcutState()
            DebugLogger.shared.debug("NSEvent monitor: Shortcut conflict while recording: \(conflictMessage)", source: "ContentView")
            return nil
        }

        self.shortcutRecordingMessage = nil
        if let recordingTarget {
            self.assignRecordedShortcut(newShortcut, to: recordingTarget)
        }
        self.resetPendingShortcutState()
        DebugLogger.shared.debug("NSEvent monitor: Finished recording shortcut", source: "ContentView")
        return nil
    }

    private func handleShortcutMouseDownEvent(
        _ event: NSEvent,
        modifiers eventModifiers: NSEvent.ModifierFlags,
        isRecordingAnyShortcut: Bool,
        recordingTarget: ShortcutRecordingTarget?
    ) -> NSEvent? {
        guard isRecordingAnyShortcut else {
            self.shortcutRecordingMessage = nil
            self.resetPendingShortcutState()
            return event
        }

        let newShortcut = HotkeyShortcut(mouseButton: event.buttonNumber, modifierFlags: self.pendingModifierFlags.union(eventModifiers))
        DebugLogger.shared.debug("NSEvent monitor: Recording new mouse shortcut: \(newShortcut.displayString)", source: "ContentView")

        if newShortcut.isUnmodifiedLeftOrRightClick, let mouseButton = newShortcut.mouseButton {
            self.shortcutRecordingMessage = "\(HotkeyShortcut.mouseButtonToString(mouseButton)) needs a modifier key"
            self.resetPendingShortcutState()
            return event
        }

        if let recordingTarget,
           let conflictMessage = self.shortcutConflictMessage(for: newShortcut, target: recordingTarget)
        {
            self.shortcutRecordingMessage = conflictMessage
            self.resetPendingShortcutState()
            DebugLogger.shared.debug("NSEvent monitor: Mouse shortcut conflict while recording: \(conflictMessage)", source: "ContentView")
            return nil
        }

        self.shortcutRecordingMessage = nil
        if let recordingTarget {
            self.assignRecordedShortcut(newShortcut, to: recordingTarget)
        }
        self.resetPendingShortcutState()
        DebugLogger.shared.debug("NSEvent monitor: Finished recording mouse shortcut", source: "ContentView")
        return nil
    }

    private func handleShortcutFlagsChangedEvent(
        _ event: NSEvent,
        modifiers eventModifiers: NSEvent.ModifierFlags,
        isRecordingAnyShortcut: Bool,
        recordingTarget: ShortcutRecordingTarget?
    ) -> NSEvent? {
        guard isRecordingAnyShortcut else {
            self.shortcutRecordingMessage = nil
            self.resetPendingShortcutState()
            return event
        }

        let changedModifierFlag = HotkeyShortcut.modifierFlag(forKeyCode: event.keyCode)

        if eventModifiers.isEmpty {
            if self.pendingModifierOnly, let modifierKeyCode = pendingModifierKeyCode {
                let newShortcut = HotkeyShortcut(
                    keyCode: modifierKeyCode,
                    modifierFlags: self.pendingModifierFlags,
                    modifierKeyCodes: Array(self.pendingModifierKeyCodes)
                )
                DebugLogger.shared.debug("NSEvent monitor: Recording modifier-only shortcut: \(newShortcut.displayString)", source: "ContentView")

                if let recordingTarget,
                   let conflictMessage = self.shortcutConflictMessage(for: newShortcut, target: recordingTarget)
                {
                    self.shortcutRecordingMessage = conflictMessage
                    self.resetPendingShortcutState()
                    DebugLogger.shared.debug("NSEvent monitor: Modifier shortcut conflict while recording: \(conflictMessage)", source: "ContentView")
                    return nil
                }

                self.shortcutRecordingMessage = nil
                if let recordingTarget {
                    self.assignRecordedShortcut(newShortcut, to: recordingTarget)
                }
                self.resetPendingShortcutState()
                DebugLogger.shared.debug("NSEvent monitor: Finished recording modifier shortcut", source: "ContentView")
                return nil
            }

            self.resetPendingShortcutState()
            DebugLogger.shared.debug("NSEvent monitor: Modifiers released without recording, continuing to wait", source: "ContentView")
            return nil
        }

        if let changedModifierFlag {
            let isRelease = self.currentRecordingModifierKeyCodes.contains(event.keyCode)

            if isRelease {
                self.currentRecordingModifierKeyCodes.remove(event.keyCode)
            } else if eventModifiers.contains(changedModifierFlag) {
                self.currentRecordingModifierKeyCodes.insert(event.keyCode)
                self.pendingModifierKeyCodes.insert(event.keyCode)
                self.pendingModifierFlags = self.pendingModifierFlags.union(eventModifiers)
                self.pendingModifierKeyCode = event.keyCode
                self.pendingModifierOnly = true
                DebugLogger.shared.debug("NSEvent monitor: Modifier key pressed during recording, pending modifiers: \(self.pendingModifierFlags)", source: "ContentView")
            }
        }
        return nil
    }

    // MARK: - Model info

    private func currentTranscriptionModelInfo() -> (provider: String, model: String) {
        let selectedModel = SettingsStore.shared.selectedSpeechModel
        return (
            provider: selectedModel.provider.rawValue.lowercased(),
            model: selectedModel.rawValue
        )
    }

    // MARK: - Mode Transition Handler

    /// Centralized handler for sidebar mode transitions to ensure proper cleanup and state management
    private func handleModeTransition(from oldValue: SidebarItem?, to newValue: SidebarItem?) {
        DebugLogger.shared.debug("Mode transition: \(String(describing: oldValue)) → \(String(describing: newValue))", source: "ContentView")

        // All views use dictation mode.
        self.menuBarManager.setOverlayMode(.dictation)
    }

    @MainActor
    private func handleMenuBarNavigation(_ destination: MenuBarNavigationDestination?) {
        guard let destination else { return }
        defer { menuBarManager.requestedNavigationDestination = nil }
        guard !self.settings.shouldShowOnboarding else { return }

        switch destination {
        case .customDictionary:
            self.selectedSidebarItem = .customDictionary
        case .preferences:
            self.selectedSidebarItem = .preferences
        }
    }

    private func handlePendingAppNavigation() {
        guard let destination = AppNavigationRouter.shared.consumePendingDestination() else { return }

        switch destination {
        case .history:
            self.selectedSidebarItem = .history
        case .keyboardShortcuts:
            self.selectedSidebarItem = .keyboardShortcuts
        case .overlaySettings:
            self.selectedSidebarItem = .overlaySettings
        }
    }

    private func resetPendingShortcutState() {
        self.currentRecordingModifierKeyCodes = []
        self.pendingModifierKeyCodes = []
        self.pendingModifierFlags = []
        self.pendingModifierKeyCode = nil
        self.pendingModifierOnly = false
    }

    private func shortcutConflictMessage(for shortcut: HotkeyShortcut, target: ShortcutRecordingTarget) -> String? {
        if shortcut.isMouseShortcut {
            guard target.allowsMouseShortcut else {
                return "Mouse clicks can only be assigned to Primary Dictation or Paste Last Transcription"
            }

            if shortcut.isUnmodifiedLeftOrRightClick, let mouseButton = shortcut.mouseButton {
                return "\(HotkeyShortcut.mouseButtonToString(mouseButton)) needs a modifier key"
            }
        }

        let replacingPrimaryIndex = target.primaryDictationReplacementIndex
        for (index, configuredShortcut) in self.primaryDictationShortcuts.enumerated() where replacingPrimaryIndex != index {
            if configuredShortcut == shortcut {
                return "Duplicate with Primary Dictation Shortcut"
            }
            if shortcut.conflictsWith(configuredShortcut) {
                return "Overlaps Primary Dictation Shortcut — use a different modifier key"
            }
        }

        var configuredShortcuts: [(ShortcutRecordingTarget, HotkeyShortcut)] = [
            (.cancel, self.cancelRecordingHotkeyShortcut),
        ]
        if self.isPromptModeShortcutEnabled {
            configuredShortcuts.append((.secondaryDictation, self.promptModeHotkeyShortcut))
        }
        let optionalConfiguredShortcuts: [(ShortcutRecordingTarget, HotkeyShortcut?)] = [
            (.pasteLast, self.pasteLastTranscriptionHotkeyShortcut),
        ]

        for (otherTarget, configuredShortcut) in configuredShortcuts where otherTarget != target {
            if configuredShortcut == shortcut {
                return "Duplicate with \(otherTarget.title)"
            }
            if shortcut.conflictsWith(configuredShortcut) {
                return "Overlaps \(otherTarget.title) — use a different modifier key"
            }
        }
        for (otherTarget, configuredShortcut) in optionalConfiguredShortcuts where otherTarget != target {
            guard let configuredShortcut else { continue }
            if configuredShortcut == shortcut {
                return "Duplicate with \(otherTarget.title)"
            }
            if shortcut.conflictsWith(configuredShortcut) {
                return "Overlaps \(otherTarget.title) — use a different modifier key"
            }
        }

        return nil
    }

    private func assignRecordedShortcut(_ shortcut: HotkeyShortcut, to target: ShortcutRecordingTarget) {
        self.applyRecordedShortcut(shortcut, to: target)
        if target.enablesFeatureOnAssignment {
            self.setShortcutTargetEnabled(true, for: target)
        }
        self.setShortcutRecording(false, for: target)
    }

    private func applyRecordedShortcut(_ shortcut: HotkeyShortcut, to target: ShortcutRecordingTarget) {
        switch target {
        case let .primaryDictation(edit):
            self.applyPrimaryDictationShortcut(shortcut, edit: edit)
        case .secondaryDictation:
            self.promptModeHotkeyShortcut = shortcut
            SettingsStore.shared.promptModeHotkeyShortcut = shortcut
            self.hotkeyManager?.updatePromptModeShortcut(shortcut)
        case .cancel:
            self.cancelRecordingHotkeyShortcut = shortcut
            SettingsStore.shared.cancelRecordingHotkeyShortcut = shortcut
        case .pasteLast:
            // The hotkey manager reads this shortcut directly from SettingsStore, so no manager update is needed.
            self.pasteLastTranscriptionHotkeyShortcut = shortcut
            SettingsStore.shared.pasteLastTranscriptionHotkeyShortcut = shortcut
        }
    }

    private func applyPrimaryDictationShortcut(_ shortcut: HotkeyShortcut, edit: PrimaryDictationShortcutEdit) {
        var shortcuts = self.primaryDictationShortcuts
        switch edit {
        case .add:
            shortcuts.append(shortcut)
        case let .replace(index):
            if shortcuts.indices.contains(index) {
                shortcuts[index] = shortcut
            } else {
                shortcuts.append(shortcut)
            }
        }
        self.primaryDictationShortcuts = shortcuts
    }

    private func setShortcutTargetEnabled(_ enabled: Bool, for target: ShortcutRecordingTarget) {
        switch target {
        case .secondaryDictation:
            self.isPromptModeShortcutEnabled = enabled
            SettingsStore.shared.promptModeShortcutEnabled = enabled
            self.hotkeyManager?.updatePromptModeShortcutEnabled(enabled)
        case .pasteLast:
            self.isPasteLastTranscriptionShortcutEnabled = enabled
            SettingsStore.shared.pasteLastTranscriptionShortcutEnabled = enabled
        case .primaryDictation, .cancel:
            break
        }
    }

    private func setShortcutRecording(_ isRecording: Bool, for target: ShortcutRecordingTarget) {
        if isRecording {
            self.activeShortcutRecordingTarget = target
        } else if self.activeShortcutRecordingTarget == target {
            self.activeShortcutRecordingTarget = nil
        }
    }

    private func clearShortcutRecordingMode() {
        self.activeShortcutRecordingTarget = nil
        self.shortcutRecordingMessage = nil
        self.resetPendingShortcutState()
    }

    private func openIssueReportingPage() {
        guard let url = URL(string: "https://thevibefather.com/contact") else { return }
        NSWorkspace.shared.open(url)
    }

    private var sidebarView: some View {
        VStack(spacing: 0) {
            self.sidebarBrandHeader

            List(selection: self.$selectedSidebarItem) {
                ForEach(SidebarNavigationCatalog.sections, id: \.id) { section in
                    Section {
                        ForEach(section.entries, id: \.item) { entry in
                            self.sidebarNavigationRow(entry.item, title: entry.title, systemImage: entry.systemImage)
                        }
                    } header: {
                        self.sidebarSectionHeader(section.title)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            self.sidebarFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(self.theme.palette.sidebarBackground)
        .animation(nil, value: self.selectedSidebarItem)
        // Brand lives in the sidebar — blank the system title slot.
        .navigationTitle("")
        .toolbar(removing: .title)
        .tint(self.theme.palette.accent)
    }

    /// Real app icon + VebeVoice + collapser — top of the sidebar column.
    private var sidebarBrandHeader: some View {
        HStack(spacing: 10) {
            self.sidebarAppIcon
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)

            Text("VebeVoice")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(self.theme.palette.primaryText)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.columnVisibility = .detailOnly
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide Sidebar")
            .accessibilityLabel("Hide Sidebar")
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(self.theme.palette.sidebarBackground)
    }

    /// Dock / app icon — not the monochrome mark glyph.
    @ViewBuilder
    private var sidebarAppIcon: some View {
        if let icon = NSApplication.shared.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Image("VebeVoiceMark")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        }
    }

    /// Words · theme · bug — parked at the bottom of the sidebar (not the titlebar).
    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(self.theme.palette.separator.opacity(0.55))
                .frame(height: 1)
                .padding(.horizontal, 12)

            HStack(spacing: 6) {
                TodayStatsToolbarButton(typingWPM: self.settings.userTypingWPM) {
                    self.selectedSidebarItem = .stats
                }
                .buttonStyle(.plain)
                .foregroundStyle(self.theme.palette.secondaryText)

                Spacer(minLength: 4)

                Button {
                    self.settings.themePreference = self.nextThemePreference(after: self.settings.themePreference)
                } label: {
                    Image(systemName: self.settings.themePreference.systemImageName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Theme: \(self.settings.themePreference.displayName)")
                .accessibilityLabel("Theme")

                Button(action: self.openIssueReportingPage) {
                    Image(systemName: "ladybug.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Report an issue")
                .accessibilityLabel("Report an issue")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(self.theme.palette.sidebarBackground)
    }

    private func sidebarSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(self.theme.typography.sidebarSection)
            .foregroundStyle(.secondary)
            .textCase(nil)
            .padding(.top, self.theme.metrics.spacing.sm)
            .padding(.bottom, self.theme.metrics.spacing.xs)
    }

    /// A selectable sidebar row. The detail pane is driven entirely by
    /// `selectedSidebarItem`, so rows carry their identity via `.tag(item)` and
    /// let `List(selection:)` own selection. Using `NavigationLink(value:)` here
    /// instead — with no matching `.navigationDestination` — sets up two
    /// competing selection systems in one sectioned outline and crashes SwiftUI's
    /// OutlineListCoordinator intermittently (EXC_BREAKPOINT/EXC_BAD_ACCESS in
    /// HeterogeneousViewIDs.subscript). Keep this a plain tagged row.
    private func sidebarNavigationRow(_ item: SidebarItem, title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(self.theme.typography.sidebarItem)
            .frame(minHeight: 24, alignment: .leading)
            .padding(.vertical, self.theme.metrics.spacing.xs / 2)
            .tag(item)
    }

    private func nextThemePreference(after preference: SettingsStore.ThemePreference) -> SettingsStore.ThemePreference {
        switch preference {
        case .system: return .light
        case .light: return .dark
        case .dark: return .system
        }
    }

    private var detailView: some View {
        ZStack {
            // Always use brand purple window color — never system gray.
            self.theme.palette.windowBackground
                .ignoresSafeArea()

            RadialGradient(
                colors: [
                    self.theme.palette.accent.opacity(self.colorScheme == .dark ? 0.16 : 0.08),
                    .clear,
                ],
                center: .top,
                startRadius: 0,
                endRadius: 560
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            self.detailContent
                .transaction { transaction in
                    transaction.animation = nil
                }
        }
    }

    private var detailContent: AnyView {
        switch self.selectedSidebarItem ?? .welcome {
        case .welcome:
            return AnyView(self.welcomeView)
        case .voiceEngine:
            return AnyView(VoiceEngineSettingsScreen(
                appServices: self.appServices,
                theme: self.theme
            ))
        case .preferences:
            return AnyView(self.preferencesView(scope: .general))
        case .keyboardShortcuts:
            return AnyView(self.preferencesView(scope: .keyboardShortcuts))
        case .overlaySettings:
            return AnyView(self.preferencesView(scope: .overlay))
        case .meetingTools:
            return AnyView(self.meetingToolsView)
        case .customDictionary:
            return AnyView(CustomDictionaryView())
        case .stats:
            return AnyView(self.statsView)
        case .history:
            return AnyView(TranscriptionHistoryView())
        case .testPlayground:
            return AnyView(TestPlaygroundView(
                playgroundUsed: self.$playgroundUsed,
                isTranscriptionFocused: self.$isTranscriptionFocused,
                stopAndProcessTranscription: { await self.stopAndProcessTranscription() },
                startRecording: self.startRecording
            ))
        case .debug:
            return AnyView(DebugLogsView())
        }
    }

    private var onboardingOnlyView: some View {
        OnboardingFlowView(
            currentStep: Binding(
                get: { self.settings.onboardingCurrentStep },
                set: { self.settings.onboardingCurrentStep = $0 }
            ),
            accessibilityEnabled: self.accessibilityEnabled,
            accessibilitySetupInProgress: self.didOpenAccessibilityPane,
            finishOnboarding: {
                self.completeOnboardingIfPossible()
            },
            openAccessibilitySettings: self.openAccessibilitySettings,
            activeShortcutRecordingTarget: self.$activeShortcutRecordingTarget,
            shortcutRecordingMessage: self.$shortcutRecordingMessage,
            theme: self.theme
        )
        .environmentObject(self.appServices)
    }

    // MARK: - Welcome Guide

    private var welcomeView: some View {
        WelcomeView(
            selectedSidebarItem: self.$selectedSidebarItem,
            playgroundUsed: self.$playgroundUsed,
            accessibilityEnabled: self.accessibilityEnabled,
            openAccessibilitySettings: self.openAccessibilitySettings
        )
    }

    private var windowSizing: VibeWindowSizing {
        let window = self.theme.metrics.window
        if self.settings.shouldShowOnboarding {
            return .minimum(width: window.onboardingMinWidth, height: window.onboardingMinHeight)
        }
        return .minimum(width: window.mainMinWidth, height: window.mainMinHeight)
    }

    // MARK: - Preferences View

    private func preferencesView(scope: SettingsPageScope) -> some View {
        SettingsView(
            pageScope: scope,
            appear: self.$appear,
            visualizerNoiseThreshold: self.$visualizerNoiseThreshold,
            selectedInputUID: self.$selectedInputUID,
            selectedOutputUID: self.$selectedOutputUID,
            microphoneSelectionMode: self.$microphoneSelectionMode,
            inputDevices: self.$inputDevices,
            outputDevices: self.$outputDevices,
            accessibilityEnabled: self.$accessibilityEnabled,
            primaryDictationShortcuts: self.$primaryDictationShortcuts,
            activeShortcutRecordingTarget: self.$activeShortcutRecordingTarget,
            shortcutRecordingMessage: self.$shortcutRecordingMessage,
            cancelRecordingShortcut: self.$cancelRecordingHotkeyShortcut,
            pasteLastTranscriptionShortcut: self.$pasteLastTranscriptionHotkeyShortcut,
            pasteLastTranscriptionShortcutEnabled: self.$isPasteLastTranscriptionShortcutEnabled,
            hotkeyManagerInitialized: self.$hotkeyManagerInitialized,
            hotkeyMode: self.$hotkeyMode,
            enableStreamingPreview: self.$enableStreamingPreview,
            copyToClipboard: self.$copyToClipboard,
            hotkeyManager: self.hotkeyManager,
            refreshDevices: self.refreshDevices,
            openAccessibilitySettings: self.openAccessibilitySettings,
            revealAppInFinder: self.revealAppInFinder,
            openApplicationsFolder: self.openApplicationsFolder
        )
    }

    // MARK: - Meeting Transcription (Coming Soon)

    private var meetingToolsView: some View {
        MeetingTranscriptionView(asrService: self.asr)
    }

    // MARK: - Stats View

    private var statsView: some View {
        StatsView()
    }

    // Audio settings merged into SettingsView

    private func refreshDevices() {
        // Query CoreAudio off the main thread — during device topology changes, synchronous
        // CoreAudio calls on main can deadlock while the HAL is still settling.
        DispatchQueue.global(qos: .userInitiated).async {
            let inputs = AudioDevice.listInputDevices()
            let outputs = AudioDevice.listOutputDevices()
            DispatchQueue.main.async {
                self.inputDevices = inputs
                self.outputDevices = outputs
            }
        }
    }

    // MARK: - App Detection and Context-Aware Prompts

    private func getCurrentAppInfo() -> (name: String, bundleId: String, windowTitle: String) {
        if let frontmostApp = NSWorkspace.shared.frontmostApplication {
            let name = frontmostApp.localizedName ?? "Unknown"
            let bundleId = frontmostApp.bundleIdentifier ?? "unknown"
            let title = self.getFrontmostWindowTitle(ownerPid: frontmostApp.processIdentifier) ?? ""
            return (name: name, bundleId: bundleId, windowTitle: title)
        }
        return (name: "Unknown", bundleId: "unknown", windowTitle: "")
    }

    /// Best-effort frontmost window title lookup for the current app
    private func getFrontmostWindowTitle(ownerPid: pid_t) -> String? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in windowInfo {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid == ownerPid else { continue }
            if let name = info[kCGWindowName as String] as? String, name.isEmpty == false {
                return name
            }
        }
        return nil
    }

    private func captureRecordingTargetContext() {
        // Capture the focused target PID BEFORE any overlay/UI changes.
        // Used to restore focus when the user interacts with overlay dropdowns.
        let focusedPID = TypingService.captureSystemFocusedPID()
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        NotchContentState.shared.recordingTargetPID = focusedPID

        let info = self.getCurrentAppInfo()
        self.recordingAppInfo = info
        DebugLogger.shared.debug(
            "Captured recording app context: app=\(info.name), bundleId=\(info.bundleId), title=\(info.windowTitle)",
            source: "ContentView"
        )
    }

    private func captureRecordingFormattingContextIfNeeded() {
        // Capture text before the caret only when formatting needs focused-field context.
        if SettingsStore.shared.needsDictationFormattingContext {
            self.recordingPrecedingText = TypingService.textBeforeCursorInFocusedField()
            DebugLogger.shared.debug(
                "Captured preceding text for continuous dictation (chars=\(self.recordingPrecedingText.count))",
                source: "ContentView"
            )
        } else {
            self.recordingPrecedingText = ""
        }
    }

    private func captureRecordingContext() {
        self.captureRecordingTargetContext()
        self.captureRecordingFormattingContextIfNeeded()
    }

    private func resolveTypingTargetPID() -> (pid: pid_t?, shouldRestoreOriginalFocus: Bool) {
        let originalPID = NotchContentState.shared.recordingTargetPID
        let currentFocusedPID = TypingService.captureSystemFocusedPID()
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier

        let selfBundleID = Bundle.main.bundleIdentifier
        if let currentFocusedPID,
           let app = NSRunningApplication(processIdentifier: currentFocusedPID),
           app.bundleIdentifier != selfBundleID
        {
            return (currentFocusedPID, currentFocusedPID == originalPID)
        }

        return (originalPID, true)
    }

    // MARK: - Stop and Process Transcription

    private func stopAndProcessTranscription(route: DictationOutputRoute = .normal) async {
        DebugLogger.shared.debug("stopAndProcessTranscription called", source: "ContentView")
        DebugLogger.shared.info("Output route selected: \(route.rawValue)", source: "ContentView")
        self.appBench("stop_path_enter route=\(route.rawValue)")

        let modeAtStop = self.activeRecordingMode
        let shouldHideOverlayOnStop = route == .normal
        var didRequestOverlayHideOnStop = false
        DebugLogger.shared.info(
            "Routing decision snapshot | activeMode=\(modeAtStop.rawValue) | overlay=\(NotchContentState.shared.mode.rawValue)",
            source: "ContentView"
        )

        self.clearActiveRecordingMode()

        if shouldHideOverlayOnStop {
            didRequestOverlayHideOnStop = true
            DebugLogger.shared.debug("Hiding dictation overlay at stop path", source: "ContentView")
            self.hideOverlayAsync(reason: "stop_path")
        } else {
            // Show "Transcribing" state before calling stop() when the overlay needs
            // to remain visible while the final transcription pass finishes.
            DebugLogger.shared.debug("Showing transcription processing state", source: "ContentView")
            self.appBench("processing_ui_request status=Transcribing")
            self.menuBarManager.setProcessing(true)
            NotchOverlayManager.shared.updateTranscriptionText("Transcribing")
            self.appBench("processing_ui_requested status=Transcribing")

            // Give SwiftUI a chance to render the processing state before heavier work.
            await Task.yield()
        }

        // Stop the ASR service and wait for transcription to complete
        // The processing indicator will stay visible during this phase
        let asrStopStartedAt = ProcessInfo.processInfo.systemUptime
        self.appBench("asr_stop_call")
        // Play the stop cue as soon as the audio engine has stopped, before the
        // (potentially slow) final transcription pass.
        let transcribedText = await asr.stop(onCaptureStopped: {
            TranscriptionSoundPlayer.shared.playStopSound()
        })
        self.appBench("asr_stop_return elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - asrStopStartedAt) * 1000).rounded()))")
        let audioSnapshot = self.asr.consumeLastCompletedAudioSnapshot()
        DebugLogger.shared.info(
            "Stop transcription result | chars=\(transcribedText.count) | empty=\(transcribedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
            source: "ContentView"
        )

        // Reset the transcription text display after transcription completes
        NotchOverlayManager.shared.updateTranscriptionText("")

        guard transcribedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            DebugLogger.shared.debug("Transcription returned empty text", source: "ContentView")
            // Finish the same short exit transition even when no text is emitted.
            if !didRequestOverlayHideOnStop {
                await self.menuBarManager.finishProcessingAndHideOverlay()
            }
            return
        }

        if NotchOverlayManager.shared.isBottomOverlayVisible {
            BottomOverlayWindowController.shared.beginReleaseTransition()
        }

        let appInfo = self.recordingAppInfo ?? self.getCurrentAppInfo()
        let normalizedTranscribedText = ASRService.applySpokenPunctuationFormatting(
            transcribedText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        let transcriptionModelInfo = self.currentTranscriptionModelInfo()

        var finalText = normalizedTranscribedText

        // Normalize literal command and mention syntax before final user preferences.
        finalText = ASRService.applyDictationLiteralFormatting(
            finalText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        // Apply GAAV formatting as the FINAL step.
        // This ensures the user's preference for no capitalization/period is respected
        finalText = ASRService.applyGAAVFormatting(finalText)
        // Apply Continuous Dictation Mode after GAAV so smart caps use the field
        // context captured at recording start, and the trailing space enables chaining.
        finalText = ASRService.applyContinuousDictationFormatting(finalText, precedingText: self.recordingPrecedingText)
        finalText = ASRService.applyTerminalLiteralAutocompleteSpacing(
            finalText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        self.recordingPrecedingText = ""
        self.asr.finalText = finalText
        if route == .onboardingSandbox,
           self.isOnboardingVoicePlaygroundStepActive,
           !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            self.settings.onboardingPlaygroundValidated = true
            self.settings.playgroundUsed = true
            self.playgroundUsed = true
        }

        DebugLogger.shared.info("Transcription finalized (chars: \(finalText.count))", source: "ContentView")
        let finalTextReadyAt = ProcessInfo.processInfo.systemUptime
        let finalOutputPlan = ASRService.makeDictationLiteralOutputPlan(
            for: finalText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        self.appBench("transcription_finalized chars=\(finalText.count)")
        self.appBench("text_ready chars=\(finalText.count)")

        let shouldPersistOutputs = route == .normal
        if !shouldPersistOutputs {
            DebugLogger.shared.info(
                "Sandbox route active: suppressing clipboard/history/external typing side effects",
                source: "ContentView"
            )
        }

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let frontmostName = frontmostApp?.localizedName ?? "Unknown"
        let isVebeVoiceFrontmost = frontmostApp?.bundleIdentifier == Bundle.main.bundleIdentifier

        // Save to transcription history (transcription mode only, if enabled)
        if shouldPersistOutputs, SettingsStore.shared.saveTranscriptionHistory {
            let historyEntryID = UUID()
            let historyTimestamp = Date()
            TranscriptionHistoryStore.shared.addEntry(
                id: historyEntryID,
                timestamp: historyTimestamp,
                rawText: transcribedText,
                processedText: finalText,
                appName: appInfo.name,
                windowTitle: appInfo.windowTitle,
                wasAIProcessed: false
            )
            self.persistDictationAudioIfNeeded(
                audioSnapshot,
                entryID: historyEntryID,
                timestamp: historyTimestamp,
                model: transcriptionModelInfo.model
            )
        }
        // Only VebeVoice's own focused editor receives `finalText` in-app; in every other
        // case (including VebeVoice frontmost with nothing focused) the clipboard is the
        // only place the transcript lands, so it must be copied.
        let isInAppEditorTarget = isVebeVoiceFrontmost && self.isTranscriptionFocused
        let shouldCopyToClipboard = shouldPersistOutputs &&
            SettingsStore.shared.copyTranscriptionToClipboard &&
            !isInAppEditorTarget

        if shouldCopyToClipboard {
            ClipboardService.copyToClipboard(finalText)
        }

        var didTypeExternally = false
        let shouldTypeExternally = shouldPersistOutputs && !isVebeVoiceFrontmost

        DebugLogger.shared.debug(
            "Typing decision → frontmost: \(frontmostName), vebeVoiceFrontmost: \(isVebeVoiceFrontmost), editorFocused: \(self.isTranscriptionFocused), willTypeExternally: \(shouldTypeExternally)",
            source: "ContentView"
        )

        if shouldTypeExternally {
            let typingTarget = self.resolveTypingTargetPID()
            // Dispatch insertion as soon as the destination app is ready; the
            // overlay hides asynchronously after output so it cannot delay paste.
            if typingTarget.shouldRestoreOriginalFocus {
                await self.restoreFocusToRecordingTarget()
            }
            self.appBench(
                "text_ready_to_type_request elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - finalTextReadyAt) * 1000).rounded()))"
            )
            self.asr.typeOutputPlanToActiveField(
                finalOutputPlan,
                preferredTargetPID: typingTarget.pid,
                textReadyAt: finalTextReadyAt,
                tracksDictionaryCorrections: true
            )
            didTypeExternally = true
            if !didRequestOverlayHideOnStop {
                self.hideOverlayAfterOutput()
            }
        }

        if !didTypeExternally, !didRequestOverlayHideOnStop {
            self.hideOverlayAfterOutput()
        }
    }

    private func hideOverlayAfterOutput() {
        self.hideOverlayAsync(reason: "after_output")
    }

    private func advanceOverlayLifecycle() {
        self.overlayLifecycleID &+= 1
    }

    private func hideOverlayAsync(reason: String) {
        let expectedOverlayLifecycleID = self.overlayLifecycleID
        self.appBench("overlay_hide_request reason=\(reason) lifecycle=\(expectedOverlayLifecycleID)")
        Task { @MainActor in
            guard self.overlayLifecycleID == expectedOverlayLifecycleID else {
                self.appBench(
                    "overlay_hide_skipped reason=\(reason) staleLifecycle=\(expectedOverlayLifecycleID) currentLifecycle=\(self.overlayLifecycleID)"
                )
                return
            }

            let overlayHideStartedAt = ProcessInfo.processInfo.systemUptime
            await self.menuBarManager.finishProcessingAndHideOverlay()
            self.appBench(
                "overlay_hidden reason=\(reason) elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - overlayHideStartedAt) * 1000).rounded()))"
            )
        }
    }

    private func persistDictationAudioIfNeeded(
        _ snapshot: DictationAudioSnapshot?,
        entryID: UUID,
        timestamp: Date,
        model: String
    ) {
        guard SettingsStore.shared.saveTranscriptionHistory,
              SettingsStore.shared.saveAudioWithTranscriptionHistory,
              let snapshot = snapshot
        else {
            return
        }

        Task.detached(priority: .utility) {
            let result: (metadata: DictationAudioMetadata?, error: String?) = {
                do {
                    let metadata = try DictationAudioHistoryStore.shared.save(
                        snapshot: snapshot,
                        entryID: entryID,
                        timestamp: timestamp,
                        model: model
                    )
                    return (metadata, nil)
                } catch {
                    return (nil, error.localizedDescription)
                }
            }()

            await MainActor.run {
                if let metadata = result.metadata {
                    TranscriptionHistoryStore.shared.attachAudio(metadata, to: entryID)
                } else if let error = result.error {
                    DebugLogger.shared.error("Failed to save dictation audio: \(error)", source: "ContentView")
                }
            }
        }
    }

    private var isOnboardingVoicePlaygroundStepActive: Bool {
        let onboardingPlaygroundStep = 4
        return !self.settings.onboardingCompleted &&
            self.settings.onboardingCurrentStep == onboardingPlaygroundStep
    }

    private var isOnboardingSandboxRouteActive: Bool {
        self.isOnboardingVoicePlaygroundStepActive
    }

    private func currentDictationOutputRouteForHotkeyStop() -> DictationOutputRoute {
        let isDictationMode = self.activeRecordingMode == .dictate || self.activeRecordingMode == .promptMode

        if self.isOnboardingSandboxRouteActive && isDictationMode {
            return .onboardingSandbox
        }
        return .normal
    }

    private func copyLastDictationFromHistory() {
        guard let text = TranscriptionHistoryStore.shared.latestClipboardText else {
            DebugLogger.shared.info("Actions: Copy requested but no transcription is available", source: "ContentView")
            return
        }

        _ = ClipboardService.copyToClipboard(text)
        DebugLogger.shared.info("Actions: Copied latest transcription to clipboard", source: "ContentView")
    }

    /// Re-inserts the most recent transcription into the focused text field using the same
    /// clipboard-free insertion path as live dictation. Unlike copy, this never touches the
    /// system clipboard, and unlike reprocess, it pastes the existing text verbatim (no new
    /// history entry, no reformatting). Useful when the original auto-insert dropped the tail.
    private func pasteLastDictationFromHistory() {
        guard let last = TranscriptionHistoryStore.shared.entries.first else {
            DebugLogger.shared.info("Actions: Paste requested but history is empty", source: "ContentView")
            return
        }

        // Prefer the processed text (what was actually delivered),
        // falling back to raw for older entries or when processed text is empty.
        let processed = last.processedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = last.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = processed.isEmpty ? raw : processed
        guard !text.isEmpty else {
            DebugLogger.shared.info("Actions: Paste skipped because latest history text is empty", source: "ContentView")
            return
        }

        Task { @MainActor in
            // Only one paste may be pending at a time. Because the paste waits for the modifier keys
            // to release, a quick double/triple-tap of the chord would otherwise queue several Tasks
            // that all insert at once on release. This collapses them to a single paste while still
            // allowing a deliberate repeat (press, it lands, then press again).
            guard !Self.isPasteLastInProgress else {
                DebugLogger.shared.info("Actions: Paste skipped - a paste is already pending", source: "ContentView")
                return
            }
            Self.isPasteLastInProgress = true
            defer { Self.isPasteLastInProgress = false }

            // The hotkey fires on key-down while its own modifier keys (e.g. ⌘⌃) are still
            // physically held. Synthesizing text in that state makes the target app treat the
            // characters as keyboard shortcuts and drop them, so the paste lands once the keys are
            // released — effectively "paste when you let go". The timeout is generous so a normal
            // hold (or a quick repeated press) still pastes on release; it only aborts if a modifier
            // is genuinely stuck, rather than typing a corrupted/destructive shortcut sequence.
            guard await Self.waitForHotkeyModifiersReleased(timeout: 5) else {
                DebugLogger.shared.info("Actions: Paste aborted - modifier keys still held after timeout", source: "ContentView")
                return
            }

            // Re-check here rather than only at the hotkey trigger: the overlay menu entry point
            // has no pre-check, and the wait above may have elapsed since the trigger fired.
            guard !self.asr.isRunning else {
                DebugLogger.shared.info("Actions: Paste skipped - recording in progress", source: "ContentView")
                return
            }

            let typingTarget = self.resolveTypingTargetPID()
            guard typingTarget.pid != nil else {
                DebugLogger.shared.info("Actions: Paste skipped - no external target field available", source: "ContentView")
                return
            }
            if typingTarget.shouldRestoreOriginalFocus {
                await self.restoreFocusToRecordingTarget()
            }
            let appInfo = self.getCurrentAppInfo()
            let outputPlan = ASRService.makeDictationLiteralOutputPlan(
                for: text,
                appName: appInfo.name,
                bundleID: appInfo.bundleId,
                windowTitle: appInfo.windowTitle
            )
            self.asr.typeOutputPlanToActiveField(outputPlan, preferredTargetPID: typingTarget.pid)
            DebugLogger.shared.info("Actions: Pasted latest transcription into focused field", source: "ContentView")
        }
    }

    /// Guards against overlapping paste insertions: only one "paste last transcription" may be
    /// pending at a time (see pasteLastDictationFromHistory). A rapid re-tap while one is still
    /// waiting for the modifier keys to release is ignored rather than queuing a duplicate insert.
    /// Only ever touched on the main actor.
    private static var isPasteLastInProgress = false

    /// Polls until the keyboard modifier keys are released, returning `true` once they are, or
    /// `false` if the timeout elapses with keys still held. Used before synthesizing a paste so the
    /// inserted characters aren't swallowed as modifier+key shortcuts.
    private static func waitForHotkeyModifiersReleased(timeout: TimeInterval) async -> Bool {
        let relevant: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.isDisjoint(with: relevant) {
                return true
            }
            try? await Task.sleep(nanoseconds: 15_000_000) // 15ms
        }
        return false
    }

    private func setActiveRecordingMode(_ mode: ActiveRecordingMode) {
        self.activeRecordingMode = mode
    }

    private func clearActiveRecordingMode() {
        self.setActiveRecordingMode(.none)
    }

    /// Cancel any in-flight background dictation task. Called on abort / new recording start.
    private func cancelPrewarmDictationIfNeeded() {
        self.prewarmDictationTask?.cancel()
        self.prewarmDictationTask = nil
    }

    /// Capture app context at start to avoid mismatches if the user switches apps mid-session
    private func startRecording() {
        let model = SettingsStore.shared.selectedSpeechModel
        DebugLogger.shared.info(
            "ContentView: startRecording() for model=\(model.displayName), supportsStreaming=\(model.supportsStreaming)",
            source: "ContentView"
        )

        self.advanceOverlayLifecycle()
        self.setActiveRecordingMode(.dictate)
        let shouldPlayStartSound = self.asr.micStatus == .authorized

        self.menuBarManager.setOverlayMode(.dictation)

        Task {
            if shouldPlayStartSound, !self.asr.isRunning {
                TranscriptionSoundPlayer.shared.playStartSound()
            }
            await self.asr.start(onCaptureStarted: {
                self.captureRecordingContext()
                self.menuBarManager.showRecordingOverlayImmediately()
            })
            if !self.asr.isRunning {
                self.menuBarManager.hideRecordingOverlayImmediately(reason: "asr_start_failed")
            }
        }

        // Pre-load model in background while recording (avoids 10s freeze on stop)
        Task {
            do {
                DebugLogger.shared.debug("ContentView: pre-load model task started", source: "ContentView")
                try await self.asr.ensureAsrReady()
                DebugLogger.shared.debug("Model pre-loaded during recording", source: "ContentView")
            } catch {
                DebugLogger.shared.error("Failed to pre-load model: \(error)", source: "ContentView")
            }
        }
    }

    /// Best-effort: re-activate the app that was focused when recording started.
    /// Skips the AX restore work when the captured text element is already focused.
    private func restoreFocusToRecordingTarget() async {
        guard let pid = NotchContentState.shared.recordingTargetPID else { return }
        let startedAt = ProcessInfo.processInfo.systemUptime
        self.appBench("focus_restore_start targetPID=\(pid)")
        if TypingService.isCapturedFocusStillActive(for: pid) {
            self.appBench("focus_restore_result activated=false element=true elapsedMs=0 reason=already_focused")
            DebugLogger.shared.debug(
                "Restore focus skipped; captured element still focused, targetPID: \(pid)",
                source: "ContentView"
            )
            self.appBench("focus_restore_settle_done delayMs=0")
            return
        }
        let activated = TypingService.activateApp(pid: pid)
        let focusedElementRestored = TypingService.restoreCapturedFocus(in: pid)
        self.appBench(
            "focus_restore_result activated=\(activated) element=\(focusedElementRestored) elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1000).rounded()))"
        )
        DebugLogger.shared.debug(
            "Restore focus -> appActivated: \(activated), elementFocusRestored: \(focusedElementRestored), targetPID: \(pid)",
            source: "ContentView"
        )
        self.appBench("focus_restore_settle_done delayMs=0")
    }

    // MARK: - ASR Model Management

    // MARK: - ASR Model Preloading

    private func preloadASRModel() async {
        // DEPRECATED: No longer auto-loads on startup - models downloaded manually
        DebugLogger.shared.debug("Skipping auto-preload - models downloaded manually via UI", source: "ContentView")
    }

    private func initializeHotkeyManagerIfNeeded() {
        NotchContentState.shared.onCopyLastRequested = {
            self.copyLastDictationFromHistory()
        }
        NotchContentState.shared.onPasteLastRequested = {
            self.pasteLastDictationFromHistory()
        }
        NotchContentState.shared.onOpenPreferencesRequested = {
            self.menuBarManager.openPreferencesFromUI()
        }
        NotchContentState.shared.onCancelRequested = {
            _ = self.handleCancelShortcut()
        }

        guard self.hotkeyManager == nil else { return }

        self.hotkeyManager = GlobalHotkeyManager(
            asrService: self.asr,
            primaryShortcuts: self.primaryDictationShortcuts,
            promptModeShortcut: self.promptModeHotkeyShortcut,
            promptModeShortcutEnabled: self.isPromptModeShortcutEnabled,
            startRecordingCallback: {
                DebugLogger.shared.debug("ContentView: startRecordingCallback invoked by hotkey", source: "ContentView")
                self.startRecording()
            },
            dictationModeCallback: {
                DebugLogger.shared.info("Dictate mode triggered", source: "ContentView")
                DebugLogger.shared.debug(
                    "ContentView: selected model for dictate hotkey=\(SettingsStore.shared.selectedSpeechModel.displayName)",
                    source: "ContentView"
                )
                self.beginDictationRecording(mode: .dictate)
            },
            stopAndProcessCallback: {
                let route = self.currentDictationOutputRouteForHotkeyStop()
                DebugLogger.shared.info("Hotkey stop callback using route: \(route.rawValue)", source: "ContentView")
                await self.stopAndProcessTranscription(route: route)
            },
            promptModeCallback: {
                DebugLogger.shared.info("Secondary dictation triggered", source: "ContentView")
                self.beginDictationRecording(mode: .promptMode)
            },
            isDictateRecordingProvider: {
                self.activeRecordingMode == .dictate
            },
            isPromptModeRecordingProvider: {
                self.activeRecordingMode == .promptMode
            },
            isShortcutCaptureActiveProvider: {
                self.isRecordingAnyShortcutCapture
            }
        )

        self.hotkeyManagerInitialized = self.hotkeyManager?.validateEventTapHealth() ?? false

        self.hotkeyManager?.setHotkeyMode(self.hotkeyMode)

        // Set cancel callback for Escape key handling (closes transient UI, resets recording state)
        // Returns true if it handled something (so GlobalHotkeyManager knows to consume the event)
        self.hotkeyManager?.setCancelCallback {
            var handled = false

            // The suggestion panel is non-activating, so its Escape key arrives
            // through the global event tap while the target app stays focused.
            if DictionaryCorrectionOverlayController.shared.isPresented {
                DebugLogger.shared.debug("Cancel callback: closing dictionary suggestion", source: "ContentView")
                DictionaryCorrectionOverlayController.shared.dismiss()
                return true
            }

            // Reset recording mode flags
            if self.activeRecordingMode != .none {
                self.cancelPrewarmDictationIfNeeded()
                self.clearActiveRecordingMode()
                handled = true
            }

            return handled
        }

        // Re-insert the most recent transcription on demand (no clipboard involved).
        self.hotkeyManager?.setPasteLastTranscriptionCallback {
            self.pasteLastDictationFromHistory()
        }

        // Monitor initialization status
        Task {
            // Give some time for initialization
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds

            await MainActor.run {
                self.hotkeyManagerInitialized = self.hotkeyManager?.validateEventTapHealth() ?? false
                DebugLogger.shared.debug("Initial hotkey manager health check: \(self.hotkeyManagerInitialized)", source: "ContentView")

                // If still not initialized and accessibility is enabled, try reinitializing
                if !self.hotkeyManagerInitialized && self.accessibilityEnabled {
                    self.hotkeyManagerInitialized = self.hotkeyManager?.validateEventTapHealth() ?? false
                    DebugLogger.shared.debug("Initial hotkey manager health check: \(self.hotkeyManagerInitialized)", source: "ContentView")

                    // If still not initialized and accessibility is enabled, try reinitializing
                    if !self.hotkeyManagerInitialized && self.accessibilityEnabled {
                        DebugLogger.shared.debug("Hotkey manager not healthy, attempting reinitalization", source: "ContentView")
                        self.hotkeyManager?.reinitialize()
                    }
                }
            }
        }
    }

    @discardableResult
    private func handleCancelShortcut() -> Bool {
        var handled = false

        if DictionaryCorrectionOverlayController.shared.isPresented {
            DebugLogger.shared.debug("Cancel shortcut: closing dictionary suggestion", source: "ContentView")
            DictionaryCorrectionOverlayController.shared.dismiss()
            return true
        }

        if self.asr.isRunning {
            DebugLogger.shared.debug("Cancel shortcut: cancelling ASR recording", source: "ContentView")
            Task { await self.asr.stopWithoutTranscription() }
            self.cancelPrewarmDictationIfNeeded()
            handled = true
        }

        if NotchOverlayManager.shared.isBottomOverlayVisible {
            DebugLogger.shared.debug("Cancel shortcut: hiding recording overlay", source: "ContentView")
            NotchOverlayManager.shared.hide()
            handled = true
        }

        return handled
    }

    // Deprecated: hotkey persistence is handled via SettingsStore
}

// SidebarItem enum moved to top of file

// AudioDevice and AudioHardwareObserver moved to Services/AudioDeviceService.swift

// MARK: - ContentView Playground & Onboarding Helpers

extension ContentView {
    private func beginDictationRecording(mode: ActiveRecordingMode) {
        DebugLogger.shared.debug("Begin dictation recording mode=\(mode.rawValue)", source: "ContentView")
        self.appBench("begin_recording mode=\(mode.rawValue)")
        if self.isOnboardingVoicePlaygroundStepActive {
            self.asr.finalText = ""
            self.settings.onboardingPlaygroundValidated = false
            self.settings.onboardingPlaygroundSkipped = false
            self.settings.playgroundUsed = false
            self.playgroundUsed = false
        }
        self.setActiveRecordingMode(mode)

        guard !self.asr.isRunning else {
            self.appBench("asr_start_skipped reason=already_running")
            return
        }
        self.advanceOverlayLifecycle()
        Task {
            let asrStartStartedAt = ProcessInfo.processInfo.systemUptime
            DebugLogger.shared.benchmark("APP_BENCH", message: "asr_start_call", source: "AppBenchmark")
            if !self.asr.isRunning {
                TranscriptionSoundPlayer.shared.playStartSound()
            }
            await self.asr.start(onCaptureStarted: {
                self.captureRecordingContext()
                self.appBench("overlay_mode_request mode=Dictation")
                self.menuBarManager.setOverlayMode(.dictation)
                self.menuBarManager.showRecordingOverlayImmediately()
                self.appBench("overlay_mode_requested mode=Dictation")
            })
            if !self.asr.isRunning {
                self.menuBarManager.hideRecordingOverlayImmediately(reason: "asr_start_failed")
            }
            DebugLogger.shared.benchmark(
                "APP_BENCH",
                message: "asr_start_return elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - asrStartStartedAt) * 1000).rounded()))",
                source: "AppBenchmark"
            )
        }
    }

    private func appBench(_ message: String) {
        DebugLogger.shared.benchmark("APP_BENCH", message: message, source: "AppBenchmark")
    }

    private var onboardingVoiceModelReady: Bool {
        self.asr.isAsrReady
    }

    private var onboardingMicrophoneReady: Bool {
        self.asr.micStatus == .authorized
    }

    private var onboardingAccessibilityReady: Bool {
        self.accessibilityEnabled
    }

    private var onboardingPlaygroundReady: Bool {
        self.settings.onboardingPlaygroundValidated || self.settings.onboardingPlaygroundSkipped
    }

    @MainActor
    private func revealAppInFinder() {
        let appPath = Bundle.main.bundlePath
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: appPath)])
    }

    private func openApplicationsFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
    }
}

// MARK: - ContentView Accessibility & Lifecycle Helpers

extension ContentView {
    func completeOnboardingIfPossible(selecting target: SidebarItem? = nil) {
        let missingRequirements = self.missingOnboardingCompletionRequirements()
        guard missingRequirements.isEmpty else {
            self.presentOnboardingCompletionBlocked(missingRequirements)
            return
        }

        self.completeOnboarding(selecting: target)
    }

    private func completeOnboarding(selecting target: SidebarItem? = nil) {
        self.settings.onboardingCompleted = true

        let isOnboarded = self.asr.isAsrReady || self.asr.modelsExistOnDisk
        self.selectedSidebarItem = target ?? (isOnboarded ? .preferences : .welcome)
    }

    private func missingOnboardingCompletionRequirements() -> [String] {
        var missing: [String] = []

        if !self.onboardingVoiceModelReady {
            missing.append("voice model")
        }
        if !self.onboardingMicrophoneReady {
            missing.append("microphone access")
        }
        if !self.onboardingAccessibilityReady {
            missing.append("Accessibility access")
        }
        if !self.onboardingPlaygroundReady {
            missing.append("test or skip")
        }

        return missing
    }

    private func presentOnboardingCompletionBlocked(_ missingRequirements: [String]) {
        let missingText = missingRequirements.joined(separator: ", ")
        DebugLogger.shared.warning(
            "Onboarding completion blocked; missing=\(missingText)",
            source: "ContentView"
        )
        self.asr.errorTitle = "Setup Isn't Complete"
        self.asr.errorMessage = "Finish \(missingText) to continue."
        self.asr.showError = true
    }

    func checkAccessibilityPermissions() -> Bool {
        return AXIsProcessTrusted()
    }

    @discardableResult
    private func refreshAccessibilityPermissionState() -> Bool {
        let trusted = self.checkAccessibilityPermissions()
        if trusted != self.accessibilityEnabled {
            self.accessibilityEnabled = trusted
        }
        return trusted
    }

    func openAccessibilitySettings() {
        let requestID = UUID()
        self.accessibilityGuideRequestID = requestID

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        self.didOpenAccessibilityPane = true
        UserDefaults.standard.set(true, forKey: self.accessibilityRestartFlagKey)
        self.startAccessibilityPolling()
        self.positionWindowBesideSystemSettings(requestID: requestID)
        self.showAccessibilityGuidePanel(requestID: requestID)
        self.activateSystemSettingsSoon(requestID: requestID)
    }

    private func positionWindowBesideSystemSettings(requestID: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard self.accessibilityGuideRequestID == requestID else { return }
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "VebeVoice" }) ?? NSApp.keyWindow else {
                return
            }

            let screen = self.systemSettingsWindowFrame()
                .flatMap { settingsFrame in
                    NSScreen.screens.first { $0.frame.intersects(settingsFrame) }
                } ?? window.screen ?? NSScreen.main
            guard let screen else { return }

            let visibleFrame = screen.visibleFrame
            let currentSize = window.frame.size
            let guideWidth = min(currentSize.width, max(640, visibleFrame.width * 0.42))
            let guideHeight = min(currentSize.height, visibleFrame.height - 56)
            let targetSize = NSSize(width: guideWidth, height: guideHeight)

            let settingsFrame = self.systemSettingsWindowFrame()
            let gap: CGFloat = 20
            let targetX: CGFloat
            if let settingsFrame, settingsFrame.maxX + gap + targetSize.width <= visibleFrame.maxX {
                targetX = settingsFrame.maxX + gap
            } else if let settingsFrame, settingsFrame.minX - gap - targetSize.width >= visibleFrame.minX {
                targetX = settingsFrame.minX - gap - targetSize.width
            } else {
                targetX = visibleFrame.maxX - targetSize.width - 24
            }

            let targetY: CGFloat
            if let settingsFrame {
                targetY = min(
                    visibleFrame.maxY - targetSize.height - 16,
                    max(visibleFrame.minY + 16, settingsFrame.maxY - targetSize.height)
                )
            } else {
                targetY = visibleFrame.midY - (targetSize.height / 2)
            }

            window.setFrame(
                NSRect(origin: NSPoint(x: targetX, y: targetY), size: targetSize),
                display: true,
                animate: true
            )
            window.orderBack(nil)
        }
    }

    private func systemSettingsWindowFrame() -> NSRect? {
        guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for info in windowList {
            guard (info[kCGWindowOwnerName as String] as? String) == "System Settings",
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? CGFloat,
                  let y = bounds["Y"] as? CGFloat,
                  let width = bounds["Width"] as? CGFloat,
                  let height = bounds["Height"] as? CGFloat,
                  width > 0,
                  height > 0
            else {
                continue
            }

            for screen in NSScreen.screens {
                let convertedFrame = NSRect(
                    x: x,
                    y: screen.frame.maxY - y - height,
                    width: width,
                    height: height
                )
                if screen.frame.intersects(convertedFrame) {
                    return convertedFrame
                }
            }

            let convertedY = (NSScreen.main?.frame.maxY ?? 0) - y - height
            return NSRect(x: x, y: convertedY, width: width, height: height)
        }

        return nil
    }

    private func showAccessibilityGuidePanel(requestID: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            guard self.accessibilityGuideRequestID == requestID else { return }
            guard !self.refreshAccessibilityPermissionState() else {
                self.finishAccessibilityPermissionFlow()
                return
            }

            let settingsFrame = self.systemSettingsWindowFrame()
            let screen = settingsFrame
                .flatMap { frame in NSScreen.screens.first { $0.frame.intersects(frame) } } ?? NSScreen.main
            guard let screen else { return }

            let visibleFrame = screen.visibleFrame
            let panelWidth = min(max((settingsFrame?.width ?? visibleFrame.width * 0.48) * 0.86, 520), 760)
            let panelHeight: CGFloat = 132
            let gap: CGFloat = 14

            let panelX: CGFloat
            let panelY: CGFloat
            if let settingsFrame {
                panelX = min(
                    visibleFrame.maxX - panelWidth - 16,
                    max(visibleFrame.minX + 16, settingsFrame.midX - (panelWidth / 2))
                )
                panelY = max(visibleFrame.minY + 16, settingsFrame.minY - panelHeight - gap)
            } else {
                panelX = visibleFrame.midX - (panelWidth / 2)
                panelY = visibleFrame.minY + 120
            }

            let frame = NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight)
            let panel = self.accessibilityGuidePanel ?? NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )

            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(
                rootView: AccessibilitySettingsFloatingGuideView(
                    appURL: self.draggableAccessibilityAppURL,
                    appName: self.accessibilityAppDisplayName,
                    onReturnToApp: {
                        self.cancelAccessibilityPermissionFlow()
                    },
                    onClose: {
                        self.cancelAccessibilityPermissionFlow()
                    }
                )
            )
            panel.setFrame(frame, display: true, animate: self.accessibilityGuidePanel != nil)
            panel.orderFrontRegardless()
            self.accessibilityGuidePanel = panel
            self.startAccessibilityGuidePanelMonitor()
            self.activateSystemSettingsSoon(requestID: requestID)
        }
    }

    private func activateSystemSettingsSoon(requestID: UUID) {
        for delay in [0.25, 0.85, 1.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard self.accessibilityGuideRequestID == requestID else { return }
                self.activateSystemSettings()
            }
        }
    }

    private func activateSystemSettings() {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.SystemSettings" }) ??
            NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.systempreferences" }) ??
            NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == "System Settings" })
        {
            app.activate(options: [])
        }
    }

    private func cancelAccessibilityPermissionFlow() {
        self.finishAccessibilityPermissionFlow()
        NSApp.activate(ignoringOtherApps: true)
        (NSApp.windows.first { $0.isVisible && $0.title == "VebeVoice" } ?? NSApp.keyWindow)?
            .makeKeyAndOrderFront(nil)
    }

    private func finishAccessibilityPermissionFlow() {
        self.accessibilityGuideRequestID = nil
        self.didOpenAccessibilityPane = false
        self.showRestartPrompt = false
        UserDefaults.standard.set(false, forKey: self.accessibilityRestartFlagKey)
        self.closeAccessibilityGuidePanel()
        self.stopAccessibilityPolling()
    }

    private func closeAccessibilityGuidePanel() {
        self.accessibilityGuideMonitorTask?.cancel()
        self.accessibilityGuideMonitorTask = nil
        self.accessibilityGuidePanel?.close()
        self.accessibilityGuidePanel = nil
    }

    private func startAccessibilityGuidePanelMonitor() {
        self.accessibilityGuideMonitorTask?.cancel()
        self.accessibilityGuideMonitorTask = Task {
            var missingSettingsCount = 0

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 900_000_000)

                let isTrusted = AXIsProcessTrusted()
                let settingsFrame = await MainActor.run {
                    self.systemSettingsWindowFrame()
                }

                if isTrusted {
                    await MainActor.run {
                        self.refreshAccessibilityPermissionState()
                        self.finishAccessibilityPermissionFlow()
                    }
                    return
                }

                if settingsFrame == nil {
                    missingSettingsCount += 1
                } else {
                    missingSettingsCount = 0
                }

                if missingSettingsCount >= 3 {
                    await MainActor.run {
                        self.cancelAccessibilityPermissionFlow()
                    }
                    return
                }
            }
        }
    }

    private var draggableAccessibilityAppURL: URL {
        let runningAppURL = Bundle.main.bundleURL
        if runningAppURL.pathExtension == "app",
           FileManager.default.fileExists(atPath: runningAppURL.path)
        {
            return runningAppURL
        }

        let installedURL = URL(fileURLWithPath: "/Applications/VebeVoice.app")
        if FileManager.default.fileExists(atPath: installedURL.path) {
            return installedURL
        }
        return Bundle.main.bundleURL
    }

    private var accessibilityAppDisplayName: String {
        Bundle.main.vibeAppDisplayName
    }

    func restartApp() {
        let appPath = Bundle.main.bundlePath
        let process = Process()
        process.launchPath = "/usr/bin/open"
        process.arguments = ["-n", appPath]
        // Clear pending flag and hide prompt before restarting
        UserDefaults.standard.set(false, forKey: self.accessibilityRestartFlagKey)
        self.showRestartPrompt = false
        try? process.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
        }
    }

    func startAccessibilityPolling() {
        // Keep polling until macOS reports the current process is trusted. The restart guard
        // only prevents restart loops; it must not prevent the UI from noticing permission changes.
        guard !self.accessibilityEnabled else { return }

        // Cancel any existing polling task
        self.accessibilityPollingTask?.cancel()

        // Start background polling
        self.accessibilityPollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // Poll every 2 seconds

                // Check if permission was granted
                let nowTrusted = AXIsProcessTrusted()
                if nowTrusted && !self.accessibilityEnabled {
                    await MainActor.run {
                        DebugLogger.shared.info("Accessibility permission granted", source: "ContentView")
                        self.refreshAccessibilityPermissionState()
                        self.finishAccessibilityPermissionFlow()

                        guard !UserDefaults.standard.bool(forKey: self.hasAutoRestartedForAccessibilityKey) else {
                            self.hotkeyManager?.reinitialize()
                            return
                        }

                        // Mark that we've auto-restarted to prevent loops.
                        UserDefaults.standard.set(true, forKey: self.hasAutoRestartedForAccessibilityKey)
                        DebugLogger.shared.info("Auto-restarting app after accessibility grant", source: "ContentView")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.restartApp()
                        }
                    }
                    break // Stop polling after triggering restart
                }
            }
        }
    }

    private func stopAccessibilityPolling() {
        self.accessibilityPollingTask?.cancel()
        self.accessibilityPollingTask = nil
    }
}

// swiftlint:enable type_body_length

private struct AccessibilitySettingsFloatingGuideView: View {
    let appURL: URL
    let appName: String
    let onReturnToApp: () -> Void
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isArrowRaised = false
    @State private var isTokenHovered = false

    private var appIcon: NSImage {
        NSWorkspace.shared.icon(forFile: self.appURL.path)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(VibeOnboardingLandingColors.blue)
                    .offset(y: self.reduceMotion ? 0 : (self.isArrowRaised ? -8 : 4))
                    .animation(
                        self.reduceMotion ? nil : .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                        value: self.isArrowRaised
                    )

                Text("Drag \(self.appName) into the Accessibility apps list as shown")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)

                Spacer()

                Button {
                    self.onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.58))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.075)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Close guide")
            }

            HStack(spacing: 12) {
                Button {
                    self.onReturnToApp()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.white.opacity(0.075)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Return to \(self.appName)")

                Image(nsImage: self.appIcon)
                    .resizable()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text(self.appName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))

                Spacer()

                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.38))
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(self.isTokenHovered ? 0.095 : 0.055))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(self.isTokenHovered ? 0.16 : 0.08), lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onHover { isHovered in
                if self.reduceMotion {
                    self.isTokenHovered = isHovered
                } else {
                    withAnimation(.easeOut(duration: 0.14)) {
                        self.isTokenHovered = isHovered
                    }
                }
            }
            .onDrag {
                NSItemProvider(object: self.appURL as NSURL)
            }
            .accessibilityLabel("Drag \(self.appName) to the Accessibility list")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.VibeBrand.panel2.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(AppTheme.VibeBrand.line.opacity(0.90), lineWidth: 1)
                )
        )
        .onAppear {
            guard !self.reduceMotion else { return }
            self.isArrowRaised = true
        }
    }
}

private struct TodayStatsToolbarButton: View {
    @ObservedObject private var historyStore = TranscriptionHistoryStore.shared

    let typingWPM: Int
    let action: () -> Void

    var body: some View {
        let summary = self.historyStore.todaySummary
        let timeSaved = summary.formattedTimeSaved(typingWPM: self.typingWPM)
        let hasActivity = summary.words > 0

        return Button(action: self.action) {
            HStack(spacing: 4) {
                Image(systemName: hasActivity ? "waveform" : "chart.bar.fill")
                if hasActivity {
                    Text("\(summary.words) words")
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(timeSaved)
                } else {
                    Text("Today")
                }
            }
            .font(.system(size: 12, weight: .medium))
        }
        .help(hasActivity ? "Today: \(summary.words) words · \(timeSaved) saved - view stats" : "View your stats")
        .accessibilityLabel("Today stats")
    }
}

// MARK: - Card Animation Modifier
