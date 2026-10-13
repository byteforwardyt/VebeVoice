import AppKit
import ApplicationServices
import Combine
import CryptoKit
import Foundation
import ServiceManagement
import SwiftUI
#if canImport(FluidAudio)
import FluidAudio
#endif

// swiftlint:disable file_length type_body_length
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    static let transcriptionPreviewCharLimitRange: ClosedRange<Int> = 50...800
    static let transcriptionPreviewCharLimitStep = 50
    static let defaultTranscriptionPreviewCharLimit = 150
    private let defaults = UserDefaults.standard
    /// Decoded shortcuts keyed by defaults key. The global event tap reads shortcuts on every
    /// keystroke, so avoid a JSON decode unless the stored bytes actually changed.
    private var decodedShortcutCache: [String: (data: Data, shortcut: HotkeyShortcut)] = [:]
    private let decodedShortcutCacheLock = NSLock()
    private(set) var launchAtStartupEnabled = false
    private(set) var launchAtStartupErrorMessage: String?
    private(set) var launchAtStartupStatusMessage =
        "VebeVoice reflects the actual macOS login item state. Unsigned or development builds may fail to enable this."

    private init() {
        self.ensureDebugLoggingDefaults()
        self.refreshLaunchAtStartupStatus(clearError: true, logMismatch: false)
    }

    enum MicrophoneSelectionMode: String, Codable, CaseIterable, Identifiable {
        case system
        case manual

        var id: String {
            self.rawValue
        }

        var displayName: String {
            switch self {
            case .system:
                return "Use macOS Default"
            case .manual:
                return "Use Preferred Microphone"
            }
        }
    }

    /// Show the main window when macOS launches VebeVoice at login (default: ON, matching
    /// current behavior). When off, login launches boot silently in the menu bar. Manual
    /// launches always show the window. Default-true semantics so existing installs keep
    /// their current behavior.
    var showMainWindowAtLoginLaunch: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.showMainWindowAtLoginLaunch)
            if value == nil { return true }
            return self.defaults.bool(forKey: Keys.showMainWindowAtLoginLaunch)
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.showMainWindowAtLoginLaunch)
        }
    }

    var enableDebugLogs: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.enableDebugLogs)
            if value == nil { return true }
            return self.defaults.bool(forKey: Keys.enableDebugLogs)
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.enableDebugLogs)
            DebugLogger.shared.refreshLoggingEnabled()
        }
    }

    private func ensureDebugLoggingDefaults() {
        if self.defaults.object(forKey: Keys.enableDebugLogs) == nil {
            self.defaults.set(true, forKey: Keys.enableDebugLogs)
        }
        DebugLogger.shared.refreshLoggingEnabled()
    }

    var primaryDictationShortcutDisplayString: String {
        let displays = self.primaryDictationShortcuts
            .map(\.displayString)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return displays.isEmpty ? Self.defaultPrimaryDictationShortcut.displayString : displays.joined(separator: " / ")
    }

    var primaryDictationShortcuts: [HotkeyShortcut] {
        get {
            let fallback = Self.defaultPrimaryDictationShortcut
            if let data = defaults.data(forKey: Keys.primaryDictationShortcutsKey),
               let shortcuts = try? JSONDecoder().decode([HotkeyShortcut].self, from: data)
            {
                return Self.normalizedPrimaryDictationShortcuts(shortcuts, fallback: fallback)
            }
            return [fallback]
        }
        set {
            objectWillChange.send()
            let shortcuts = Self.normalizedPrimaryDictationShortcuts(newValue, fallback: Self.defaultPrimaryDictationShortcut)
            self.storePrimaryDictationShortcuts(shortcuts)
        }
    }

    private static var defaultPrimaryDictationShortcut: HotkeyShortcut {
        HotkeyShortcut(keyCode: 61, modifierFlags: [])
    }

    private func storedShortcut(forKey key: String) -> HotkeyShortcut? {
        guard let data = self.defaults.data(forKey: key) else { return nil }
        self.decodedShortcutCacheLock.lock()
        let cached = self.decodedShortcutCache[key]
        self.decodedShortcutCacheLock.unlock()
        if let cached, cached.data == data { return cached.shortcut }

        guard let shortcut = try? JSONDecoder().decode(HotkeyShortcut.self, from: data) else { return nil }
        self.decodedShortcutCacheLock.lock()
        self.decodedShortcutCache[key] = (data, shortcut)
        self.decodedShortcutCacheLock.unlock()
        return shortcut
    }

    private static func normalizedPrimaryDictationShortcuts(
        _ shortcuts: [HotkeyShortcut],
        fallback: HotkeyShortcut
    ) -> [HotkeyShortcut] {
        var unique: [HotkeyShortcut] = []
        for shortcut in shortcuts where !unique.contains(shortcut) {
            unique.append(shortcut)
        }
        if unique.isEmpty {
            unique.append(fallback)
        }
        return unique
    }

    private func storePrimaryDictationShortcuts(_ shortcuts: [HotkeyShortcut]) {
        if let data = try? JSONEncoder().encode(shortcuts) {
            self.defaults.set(data, forKey: Keys.primaryDictationShortcutsKey)
        }
    }

    var hotkeyMode: HotkeyActivationMode {
        get { self.defaults.string(forKey: Keys.hotkeyMode).flatMap(HotkeyActivationMode.init(rawValue:)) ?? .toggle }
        set { objectWillChange.send(); self.defaults.set(newValue.rawValue, forKey: Keys.hotkeyMode) }
    }

    var enableStreamingPreview: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.enableStreamingPreview)
            return value as? Bool ?? true // Default to true (enabled)
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.enableStreamingPreview)
        }
    }

    /// Direct Core Audio capture is enabled by default for faster recording
    /// startup, while preserving explicit user opt-out.
    var experimentalDirectAudioCaptureEnabled: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.experimentalDirectAudioCaptureEnabled)
            return value as? Bool ?? true
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.experimentalDirectAudioCaptureEnabled)
        }
    }

    var directAudioCaptureConsecutiveFailures: Int {
        get { self.defaults.integer(forKey: Keys.directAudioCaptureConsecutiveFailures) }
        set { self.defaults.set(max(0, newValue), forKey: Keys.directAudioCaptureConsecutiveFailures) }
    }

    var copyTranscriptionToClipboard: Bool {
        // Default ON: the last transcription is always left on the clipboard as a
        // paste fallback in case auto-typing into the target app doesn't land.
        // (object(forKey:) so an explicit user "off" is still honored.)
        get {
            let value = self.defaults.object(forKey: Keys.copyTranscriptionToClipboard)
            return value as? Bool ?? true
        }
        set { self.defaults.set(newValue, forKey: Keys.copyTranscriptionToClipboard) }
    }

    var preferredInputDeviceUID: String? {
        get { self.defaults.string(forKey: Keys.preferredInputDeviceUID) }
        set { self.defaults.set(newValue, forKey: Keys.preferredInputDeviceUID) }
    }

    var preferredOutputDeviceUID: String? {
        get { self.defaults.string(forKey: Keys.preferredOutputDeviceUID) }
        set { self.defaults.set(newValue, forKey: Keys.preferredOutputDeviceUID) }
    }

    var microphoneSelectionMode: MicrophoneSelectionMode {
        get {
            if let raw = self.defaults.string(forKey: Keys.microphoneSelectionMode),
               let mode = MicrophoneSelectionMode(rawValue: raw)
            {
                return mode
            }

            return .system
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.microphoneSelectionMode)
        }
    }

    func recordInputDeviceSelection(_ uid: String) {
        guard uid.isEmpty == false else { return }
        guard self.microphoneSelectionMode == .manual else { return }

        self.preferredInputDeviceUID = uid
    }

    func shouldSyncInputSelectionToSystemDefault() -> Bool {
        self.microphoneSelectionMode == .system
    }

    @discardableResult
    func setMicrophoneSelectionMode(
        _ mode: MicrophoneSelectionMode,
        currentSystemInputUID: String?,
        availableInputUIDs: Set<String>
    ) -> String? {
        let previousMode = self.microphoneSelectionMode

        if previousMode == .system,
           mode == .manual,
           let currentSystemInputUID,
           currentSystemInputUID.isEmpty == false
        {
            self.defaults.set(currentSystemInputUID, forKey: Keys.systemInputDeviceUIDBeforeManual)
        }

        self.microphoneSelectionMode = mode

        guard mode == .system else { return nil }

        if let previousSystemInputUID = self.defaults.string(forKey: Keys.systemInputDeviceUIDBeforeManual),
           previousSystemInputUID.isEmpty == false,
           availableInputUIDs.contains(previousSystemInputUID)
        {
            return previousSystemInputUID
        }

        return currentSystemInputUID
    }

    var visualizerNoiseThreshold: Double {
        get {
            let value = self.defaults.double(forKey: Keys.visualizerNoiseThreshold)
            return value == 0.0 ? 0.4 : value // Default to 0.4 if not set
        }
        set {
            // Clamp between 0.0 and 0.95 to avoid division by zero issues in visualizers
            let clamped = max(min(newValue, 0.95), 0.0)
            self.defaults.set(clamped, forKey: Keys.visualizerNoiseThreshold)
        }
    }

    // MARK: - Overlay Position

    /// Size options for the recording overlay
    enum OverlaySize: String, CaseIterable, Codable {
        case pill
        case small
        case medium
        case large

        var displayName: String {
            switch self {
            case .pill: return "Pill"
            case .small: return "Small"
            case .medium: return "Medium"
            case .large: return "Large"
            }
        }
    }

    /// Vertical offset for the bottom overlay (distance from bottom of screen/dock)
    var overlayBottomOffset: Double {
        get {
            let value = self.defaults.double(forKey: Keys.overlayBottomOffset)
            return value == 0.0 ? 50.0 : value // Default to 50.0
        }
        set {
            objectWillChange.send()
            // Clamp between a safe range (20px to 1000px)
            // Even though slider is 20-500, we clamp for safety
            let clamped = max(min(newValue, 1000.0), 10.0)
            self.defaults.set(clamped, forKey: Keys.overlayBottomOffset)

            // Post notification for live update if overlay is visible
            NotificationCenter.default.post(name: NSNotification.Name("OverlayOffsetChanged"), object: nil)
        }
    }

    /// The size of the recording overlay (default: medium)
    var overlaySize: OverlaySize {
        get {
            guard let raw = self.defaults.string(forKey: Keys.overlaySize),
                  let size = OverlaySize(rawValue: raw)
            else {
                return .medium // Default to medium
            }
            return size
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.overlaySize)

            // Post notification for live update if overlay is visible
            NotificationCenter.default.post(name: NSNotification.Name("OverlaySizeChanged"), object: nil)
        }
    }

    /// How many recent transcription characters show in overlays (default: 150)
    var transcriptionPreviewCharLimit: Int {
        get {
            let stored = self.defaults.object(forKey: Keys.transcriptionPreviewCharLimit) as? NSNumber
            let value = stored?.intValue ?? Self.defaultTranscriptionPreviewCharLimit
            return Self.normalizedTranscriptionPreviewCharLimit(value)
        }
        set {
            let clamped = Self.normalizedTranscriptionPreviewCharLimit(newValue)
            guard clamped != self.transcriptionPreviewCharLimit else { return }

            objectWillChange.send()
            self.defaults.set(clamped, forKey: Keys.transcriptionPreviewCharLimit)
            NotificationCenter.default.post(
                name: NSNotification.Name("TranscriptionPreviewCharLimitChanged"),
                object: nil
            )
        }
    }

    private static func normalizedTranscriptionPreviewCharLimit(_ value: Int) -> Int {
        let range = Self.transcriptionPreviewCharLimitRange
        let clamped = max(range.lowerBound, min(range.upperBound, value))
        let offset = clamped - range.lowerBound
        let snappedOffset = Int((Double(offset) / Double(Self.transcriptionPreviewCharLimitStep)).rounded())
            * Self.transcriptionPreviewCharLimitStep
        return max(range.lowerBound, min(range.upperBound, range.lowerBound + snappedOffset))
    }

    // MARK: - Preferences Settings

    enum AccentColorOption: String, CaseIterable, Identifiable, Codable {
        case purple = "Purple" // deep brand
        case void = "Void" // primary void
        case lilac = "Lilac" // soft
        case pink = "Orchid" // fuchsia-purple
        case blue = "Iris" // cool violet
        case mint = "Grape" // mid purple
        case gold = "Lavender" // pale
        case amber = "Plum" // deep plum

        var id: String {
            self.rawValue
        }

        /// Full purple spectrum — every accent choice stays violet-family.
        var hex: String {
            switch self {
            case .purple: return "#7C3AED" // deep violet
            case .void: return "#8B5CF6" // brand void
            case .lilac: return "#A78BFA" // soft lilac
            case .pink: return "#C026D3" // orchid
            case .blue: return "#818CF8" // iris
            case .mint: return "#9333EA" // grape
            case .gold: return "#C4B5FD" // lavender
            case .amber: return "#6D28D9" // plum
            }
        }

        /// Parsed once so every read returns the same `Color` instance; a fresh
        /// instance per read makes the theme environment compare unequal and
        /// invalidates every view that reads it.
        private static let colors: [AccentColorOption: Color] = Dictionary(
            uniqueKeysWithValues: allCases.map { ($0, Color(hex: $0.hex) ?? AppTheme.VibeBrand.accent) }
        )

        var color: Color {
            Self.colors[self] ?? AppTheme.VibeBrand.accent
        }

        static func resolved(fromStored raw: String?) -> AccentColorOption {
            raw.flatMap(AccentColorOption.init(rawValue:)) ?? .void
        }
    }

    enum ThemePreference: String, CaseIterable, Identifiable, Codable {
        case system
        case light
        case dark

        var id: String {
            self.rawValue
        }

        var displayName: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }

        var systemImageName: String {
            switch self {
            case .system: return "circle.lefthalf.filled"
            case .light: return "sun.max"
            case .dark: return "moon"
            }
        }

        var preferredColorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    enum TranscriptionStartSound: String, CaseIterable, Identifiable, Codable {
        case none
        case vibeSfx0 = "vibe_sfx_0"
        case vibeSfx1 = "vibe_sfx_1"
        case vibeSfx2 = "vibe_sfx_2"
        case vibeSfx3 = "vibe_sfx_3"
        case vibeSfx4 = "vibe_sfx_4"

        var id: String {
            self.rawValue
        }

        var displayName: String {
            switch self {
            case .none: return "None"
            case .vibeSfx0: return "Vibe SFX 0"
            case .vibeSfx1: return "Vibe SFX 1"
            case .vibeSfx2: return "Vibe SFX 2"
            case .vibeSfx3: return "Vibe SFX 3"
            case .vibeSfx4: return "Vibe SFX 4"
            }
        }

        var startSoundFileName: String? {
            switch self {
            case .none: return nil
            case .vibeSfx0: return "VV_start_0"
            case .vibeSfx1: return "VV_start"
            case .vibeSfx2: return "VV_start_2"
            case .vibeSfx3: return "sfx_3"
            case .vibeSfx4: return "sfx_4"
            }
        }

        var stopSoundFileName: String? {
            switch self {
            case .vibeSfx0: return "VV_end_0"
            case .none, .vibeSfx1, .vibeSfx2, .vibeSfx3, .vibeSfx4: return nil
            }
        }
    }

    var accentColorOption: AccentColorOption {
        get {
            AccentColorOption.resolved(fromStored: self.defaults.string(forKey: Keys.accentColorOption))
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.accentColorOption)
        }
    }

    var accentColor: Color {
        self.accentColorOption.color
    }

    var themePreference: ThemePreference {
        get {
            guard let raw = self.defaults.string(forKey: Keys.themePreference),
                  let preference = ThemePreference(rawValue: raw)
            else {
                return .system
            }
            return preference
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.themePreference)
        }
    }

    var transcriptionSoundVolume: Float {
        get {
            let value = self.defaults.object(forKey: Keys.transcriptionSoundVolume)
            return (value as? Float) ?? 1.0
        }
        set {
            objectWillChange.send()
            let clamped = max(0.0, min(1.0, newValue))
            self.defaults.set(clamped, forKey: Keys.transcriptionSoundVolume)
        }
    }

    var transcriptionSoundIndependentVolume: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.transcriptionSoundIndependentVolume)
            return value as? Bool ?? false
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.transcriptionSoundIndependentVolume)
        }
    }

    var transcriptionStartSound: TranscriptionStartSound {
        get {
                guard let raw = self.defaults.string(forKey: Keys.transcriptionStartSound),
                  let option = TranscriptionStartSound(rawValue: raw)
            else {
                return .vibeSfx0
            }
            return option
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.transcriptionStartSound)
        }
    }

    func applyLaunchAtStartupStatus(enabled: Bool, statusMessage: String, errorMessage: String?) {
        objectWillChange.send()
        self.launchAtStartupEnabled = enabled
        self.launchAtStartupStatusMessage = statusMessage
        self.launchAtStartupErrorMessage = errorMessage
    }

    func applyLaunchAtStartupErrorMessage(_ message: String?) {
        objectWillChange.send()
        self.launchAtStartupErrorMessage = message
    }

    // MARK: - Initialization Methods

    func initializeAppSettings() {
        #if os(macOS)
        self.refreshLaunchAtStartupStatus(clearError: true)

        // Apply dock visibility setting on app launch
        let dockVisible = self.showInDock
        DebugLogger.shared.info("Initializing app with dock visibility: \(dockVisible)", source: "SettingsStore")

        // Set activation policy based on saved preference
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(dockVisible ? .regular : .accessory)
        }
        #endif
    }

    var showInDock: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.showInDock)
            return value as? Bool ?? true // Default to true if not set
        }
        set {
            self.defaults.set(newValue, forKey: Keys.showInDock)
            // Update dock visibility
            self.updateDockVisibility(newValue)
        }
    }

    /// Hide app from Dock and Cmd+Tab when enabled.
    /// Backed by existing `showInDock` storage to keep this change minimal.
    var hideFromDockAndAppSwitcher: Bool {
        get { !self.showInDock }
        set { self.showInDock = !newValue }
    }

    var playgroundUsed: Bool {
        get { self.defaults.bool(forKey: Keys.playgroundUsed) }
        set { self.defaults.set(newValue, forKey: Keys.playgroundUsed) }
    }

    var onboardingCompleted: Bool {
        get {
            if self.defaults.object(forKey: Keys.onboardingCompleted) == nil {
                return true
            }
            return self.defaults.bool(forKey: Keys.onboardingCompleted)
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.onboardingCompleted)
            if newValue {
                self.defaults.set(false, forKey: Keys.manualOnboardingResetRequested)
                self.defaults.removeObject(forKey: Keys.manualOnboardingResetRequestedAt)
            }
        }
    }

    var onboardingCurrentStep: Int {
        get {
            let raw = self.defaults.integer(forKey: Keys.onboardingCurrentStep)
            return max(0, min(4, raw))
        }
        set {
            objectWillChange.send()
            let clamped = max(0, min(4, newValue))
            self.defaults.set(clamped, forKey: Keys.onboardingCurrentStep)
        }
    }

    var onboardingPlaygroundValidated: Bool {
        get { self.defaults.bool(forKey: Keys.onboardingPlaygroundValidated) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.onboardingPlaygroundValidated)
        }
    }

    var onboardingPlaygroundSkipped: Bool {
        get { self.defaults.bool(forKey: Keys.onboardingPlaygroundSkipped) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.onboardingPlaygroundSkipped)
        }
    }

    var onboardingSelectedLanguageID: String {
        get {
            let stored = self.defaults.string(forKey: Keys.onboardingSelectedLanguageID)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let stored, !stored.isEmpty {
                return stored
            }
            return "en"
        }
        set {
            objectWillChange.send()
            let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            self.defaults.set(normalized.isEmpty ? "en" : normalized, forKey: Keys.onboardingSelectedLanguageID)
        }
    }

    var selectedAppleSpeechLocaleIdentifier: String {
        get {
            let stored = self.defaults.string(forKey: Keys.selectedAppleSpeechLocaleIdentifier)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let stored, !stored.isEmpty {
                return stored
            }
            return Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        }
        set {
            objectWillChange.send()
            let normalized = newValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "_", with: "-")
            self.defaults.set(normalized.isEmpty ? "en-US" : normalized, forKey: Keys.selectedAppleSpeechLocaleIdentifier)
        }
    }

    var selectedAppleSpeechLocale: Locale {
        Locale(identifier: self.selectedAppleSpeechLocaleIdentifier)
    }

    var shouldShowOnboarding: Bool {
        !self.onboardingCompleted
    }

    /// Returns true the first time the app is ever opened on this Mac.
    func recordFirstOpenIfNeeded() -> Bool {
        guard self.defaults.object(forKey: Keys.firstOpenAt) == nil else { return false }
        self.defaults.set(Date().timeIntervalSince1970, forKey: Keys.firstOpenAt)
        return true
    }

    func bootstrapOnboardingState(isTrueFirstOpen: Bool) {
        guard self.defaults.object(forKey: Keys.onboardingCompleted) == nil else { return }

        objectWillChange.send()

        if isTrueFirstOpen {
            self.defaults.set(false, forKey: Keys.onboardingCompleted)
            self.defaults.set(0, forKey: Keys.onboardingCurrentStep)
            self.defaults.set(false, forKey: Keys.onboardingPlaygroundValidated)
            self.defaults.set(false, forKey: Keys.onboardingPlaygroundSkipped)
            self.defaults.set("en", forKey: Keys.onboardingSelectedLanguageID)
        } else {
            self.defaults.set(true, forKey: Keys.onboardingCompleted)
            self.defaults.set(0, forKey: Keys.onboardingCurrentStep)
            self.defaults.set(false, forKey: Keys.onboardingPlaygroundValidated)
            self.defaults.set(false, forKey: Keys.onboardingPlaygroundSkipped)
            self.defaults.set("en", forKey: Keys.onboardingSelectedLanguageID)
        }
    }

    func resetOnboardingProgress() {
        objectWillChange.send()
        self.defaults.set(false, forKey: Keys.onboardingCompleted)
        self.defaults.set(true, forKey: Keys.manualOnboardingResetRequested)
        self.defaults.set(Date(), forKey: Keys.manualOnboardingResetRequestedAt)
        self.defaults.set(0, forKey: Keys.onboardingCurrentStep)
        self.defaults.set(false, forKey: Keys.onboardingPlaygroundValidated)
        self.defaults.set(false, forKey: Keys.onboardingPlaygroundSkipped)
        self.defaults.set("en", forKey: Keys.onboardingSelectedLanguageID)
        self.defaults.set(false, forKey: Keys.playgroundUsed)
    }

    // MARK: - Secondary Dictation Shortcut Settings

    var promptModeShortcutEnabled: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.promptModeShortcutEnabled)
            return value as? Bool ?? false
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.promptModeShortcutEnabled)
        }
    }

    var promptModeHotkeyShortcut: HotkeyShortcut {
        get {
            if let shortcut = self.storedShortcut(forKey: Keys.promptModeHotkeyShortcut) {
                return shortcut
            }
            // Default to Right Shift key (keyCode: 60, no modifiers) — avoids conflict with the primary dictation shortcut
            return HotkeyShortcut(keyCode: 60, modifierFlags: [])
        }
        set {
            objectWillChange.send()
            if let data = try? JSONEncoder().encode(newValue) {
                self.defaults.set(data, forKey: Keys.promptModeHotkeyShortcut)
            }
        }
    }

    var cancelRecordingHotkeyShortcut: HotkeyShortcut {
        get {
            if let shortcut = self.storedShortcut(forKey: Keys.cancelRecordingHotkeyShortcut) {
                return shortcut
            }
            return HotkeyShortcut(keyCode: 53, modifierFlags: [])
        }
        set {
            objectWillChange.send()
            if let data = try? JSONEncoder().encode(newValue) {
                self.defaults.set(data, forKey: Keys.cancelRecordingHotkeyShortcut)
            }
        }
    }

    // MARK: - Paste Last Transcription Settings

    /// Whether the "Paste Last Transcription" global hotkey is active. Opt-in and off by default.
    var pasteLastTranscriptionShortcutEnabled: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.pasteLastTranscriptionShortcutEnabled)
            return value as? Bool ?? false
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.pasteLastTranscriptionShortcutEnabled)
        }
    }

    /// The shortcut that re-inserts the most recent transcription into the focused field.
    /// Unbound (nil) by default so it never collides with an existing shortcut until the user assigns one.
    var pasteLastTranscriptionHotkeyShortcut: HotkeyShortcut? {
        get {
            self.storedShortcut(forKey: Keys.pasteLastTranscriptionHotkeyShortcut)
        }
        set {
            objectWillChange.send()
            guard let newValue else {
                self.defaults.removeObject(forKey: Keys.pasteLastTranscriptionHotkeyShortcut)
                return
            }
            if let data = try? JSONEncoder().encode(newValue) {
                self.defaults.set(data, forKey: Keys.pasteLastTranscriptionHotkeyShortcut)
            }
        }
    }

    // MARK: - Stats Settings

    /// User's typing speed in words per minute (for time saved calculation)
    var userTypingWPM: Int {
        get {
            let value = self.defaults.integer(forKey: Keys.userTypingWPM)
            return value > 0 ? value : 40 // Default to 40 WPM
        }
        set {
            objectWillChange.send()
            self.defaults.set(max(1, min(200, newValue)), forKey: Keys.userTypingWPM) // Clamp 1-200
        }
    }

    /// When enabled, weekends (Saturday/Sunday) don't break the usage streak
    var weekendsDontBreakStreak: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.weekendsDontBreakStreak)
            return value as? Bool ?? true // Default to true (weekends don't break streak)
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.weekendsDontBreakStreak)
        }
    }

    /// Whether to save transcription history for stats tracking
    /// When disabled, transcriptions are not stored and stats won't update
    var saveTranscriptionHistory: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.saveTranscriptionHistory)
            return value as? Bool ?? true // Default to true (save history)
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.saveTranscriptionHistory)
        }
    }

    /// Stores actual microphone audio locally alongside dictation history.
    var saveAudioWithTranscriptionHistory: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.saveAudioWithTranscriptionHistory)
            return value as? Bool ?? false
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.saveAudioWithTranscriptionHistory)
        }
    }

    var audioHistoryBudgetGB: Double {
        get {
            let value = self.defaults.double(forKey: Keys.audioHistoryBudgetGB)
            return value > 0 ? max(0.1, value) : 4.0
        }
        set {
            objectWillChange.send()
            self.defaults.set(max(0.1, newValue), forKey: Keys.audioHistoryBudgetGB)
        }
    }

    var audioHistoryBudgetBytes: Int64 {
        DictationAudioHistoryStore.bytes(forGigabytes: self.audioHistoryBudgetGB)
    }

    // MARK: - Private Methods

    private func updateDockVisibility(_ visible: Bool) {
        #if os(macOS)
        // IMPORTANT: This is a simplified implementation for development
        // In production, consider these approaches:
        // 1. Use LSUIElement in Info.plist to control default dock visibility
        // 2. Implement a proper helper app or service for dock management
        // 3. Use NSApplication.shared.setActivationPolicy() for better control

        // For now, we'll try multiple approaches with fallbacks

        DebugLogger.shared.debug(
            "Attempting to update dock visibility to: \(visible ? "visible" : "hidden")",
            source: "SettingsStore"
        )

        // Method 1: Try the deprecated TransformProcessType (may not work on all systems)
        let transformState = visible ? ProcessApplicationTransformState(kProcessTransformToForegroundApplication)
            : ProcessApplicationTransformState(kProcessTransformToUIElementApplication)

        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kCurrentProcess))
        let result = TransformProcessType(&psn, transformState)

        if result == 0 {
            DebugLogger.shared.info("✓ Dock visibility updated using TransformProcessType", source: "SettingsStore")
        } else {
            DebugLogger.shared
                .warning(
                    "⚠️ TransformProcessType failed (error: \(result)). This is expected on some macOS versions.",
                    source: "SettingsStore"
                )
            DebugLogger.shared.debug(
                "   The setting is saved and will be applied when possible.",
                source: "SettingsStore"
            )
        }

        // Method 2: Try to notify the system of the change
        // This may help with some system caches
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.setActivationPolicy(visible ? .regular : .accessory)
            DebugLogger.shared.info(
                "✓ Activation policy updated to: \(visible ? "regular" : "accessory")",
                source: "SettingsStore"
            )
        }

        // Store the intended state for reference
        UserDefaults.standard.set(visible, forKey: "IntendedDockVisibility")
        DebugLogger.shared.info("✓ Dock visibility preference saved: \(visible)", source: "SettingsStore")
        #endif
    }

    // MARK: - Filler Words

    static let defaultFillerWords = [
        "um",
        "uh",
        "er",
        "ah",
        "eh",
        "umm",
        "uhh",
        "err",
        "ahh",
        "ehh",
        "hmm",
        "hm",
        "mm",
        "mmm",
        "erm",
        "urm",
        "ugh",
    ]

    var fillerWords: [String] {
        get {
            if let stored = defaults.array(forKey: Keys.fillerWords) as? [String] {
                return stored
            }
            return Self.defaultFillerWords
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.fillerWords)
        }
    }

    var removeFillerWordsEnabled: Bool {
        get { self.defaults.object(forKey: Keys.removeFillerWordsEnabled) as? Bool ?? true }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.removeFillerWordsEnabled)
        }
    }

    var autoConvertPunctuationEnabled: Bool {
        get { self.defaults.object(forKey: Keys.autoConvertPunctuationEnabled) as? Bool ?? true }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.autoConvertPunctuationEnabled)
        }
    }

    var literalDictationFormattingEnabled: Bool {
        get { self.defaults.object(forKey: Keys.literalDictationFormattingEnabled) as? Bool ?? false }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.literalDictationFormattingEnabled)
        }
    }

    static let defaultPunctuationDictionaryPrefix = "literal"

    static let defaultPunctuationDictionaryRules: [PunctuationDictionaryRule] = [
        PunctuationDictionaryRule(aliases: ["comma"], symbol: ","),
        PunctuationDictionaryRule(aliases: ["period", "full stop"], symbol: "."),
        PunctuationDictionaryRule(aliases: ["dot"], symbol: "."),
        PunctuationDictionaryRule(aliases: ["question mark", "questionmark"], symbol: "?"),
        PunctuationDictionaryRule(aliases: ["exclamation mark", "exclamation point", "bang"], symbol: "!"),
        PunctuationDictionaryRule(aliases: ["colon"], symbol: ":"),
        PunctuationDictionaryRule(aliases: ["semicolon", "semi colon"], symbol: ";"),
        PunctuationDictionaryRule(aliases: ["ellipsis", "dot dot dot", "three dots"], symbol: "..."),
        PunctuationDictionaryRule(aliases: ["slash", "forward slash", "forwardslash"], symbol: "/"),
        PunctuationDictionaryRule(aliases: ["backslash", "back slash"], symbol: "\\"),
        PunctuationDictionaryRule(aliases: ["hyphen"], symbol: "-"),
        PunctuationDictionaryRule(aliases: ["dash", "minus sign"], symbol: "-"),
        PunctuationDictionaryRule(aliases: ["em dash", "long dash"], symbol: "—"),
        PunctuationDictionaryRule(aliases: ["en dash"], symbol: "–"),
        PunctuationDictionaryRule(
            aliases: ["open parenthesis", "open parentheses", "left parenthesis", "left parentheses", "open paren", "left paren"],
            symbol: "("
        ),
        PunctuationDictionaryRule(
            aliases: ["close parenthesis", "close parentheses", "right parenthesis", "right parentheses", "close paren", "right paren"],
            symbol: ")"
        ),
        PunctuationDictionaryRule(aliases: ["open bracket", "left bracket", "open square bracket", "left square bracket"], symbol: "["),
        PunctuationDictionaryRule(aliases: ["close bracket", "right bracket", "close square bracket", "right square bracket"], symbol: "]"),
        PunctuationDictionaryRule(
            aliases: ["open brace", "left brace", "open curly brace", "left curly brace", "open curly bracket", "left curly bracket"],
            symbol: "{"
        ),
        PunctuationDictionaryRule(
            aliases: ["close brace", "right brace", "close curly brace", "right curly brace", "close curly bracket", "right curly bracket"],
            symbol: "}"
        ),
        PunctuationDictionaryRule(aliases: ["open angle bracket", "left angle bracket", "less than sign"], symbol: "<"),
        PunctuationDictionaryRule(aliases: ["close angle bracket", "right angle bracket", "greater than sign"], symbol: ">"),
        PunctuationDictionaryRule(aliases: ["quote", "quotes", "quotation mark", "double quote"], symbol: "\""),
        PunctuationDictionaryRule(aliases: ["open quote", "opening quote", "open double quote", "opening double quote"], symbol: "\""),
        PunctuationDictionaryRule(aliases: ["close quote", "closing quote", "close double quote", "closing double quote"], symbol: "\""),
        PunctuationDictionaryRule(aliases: ["single quote"], symbol: "'"),
        PunctuationDictionaryRule(aliases: ["apostrophe"], symbol: "'"),
        PunctuationDictionaryRule(aliases: ["at the rate", "at sign", "commercial at"], symbol: "@"),
        PunctuationDictionaryRule(aliases: ["ampersand", "and sign"], symbol: "&"),
        PunctuationDictionaryRule(aliases: ["plus sign", "plus"], symbol: "+"),
        PunctuationDictionaryRule(aliases: ["equals sign", "equal sign", "equal", "equals"], symbol: "="),
        PunctuationDictionaryRule(aliases: ["percent sign", "percentage sign", "percent"], symbol: "%"),
        PunctuationDictionaryRule(aliases: ["dollar sign", "dollar"], symbol: "$"),
        PunctuationDictionaryRule(aliases: ["hash", "hash sign", "hashtag", "pound sign", "number sign"], symbol: "#"),
        PunctuationDictionaryRule(aliases: ["asterisk", "star symbol"], symbol: "*"),
        PunctuationDictionaryRule(aliases: ["underscore"], symbol: "_"),
        PunctuationDictionaryRule(aliases: ["pipe", "vertical bar"], symbol: "|"),
        PunctuationDictionaryRule(aliases: ["tilde"], symbol: "~"),
        PunctuationDictionaryRule(aliases: ["caret"], symbol: "^"),
        PunctuationDictionaryRule(aliases: ["backtick", "back tick"], symbol: "`"),
    ]

    struct PunctuationDictionaryRule: Codable, Identifiable, Hashable {
        let id: UUID
        var aliases: [String]
        var symbol: String

        init(aliases: [String], symbol: String) {
            self.id = UUID()
            self.aliases = Self.normalizedAliases(aliases)
            self.symbol = Self.normalizedSymbol(symbol) ?? symbol
        }

        init(id: UUID, aliases: [String], symbol: String) {
            self.id = id
            self.aliases = Self.normalizedAliases(aliases)
            self.symbol = Self.normalizedSymbol(symbol) ?? symbol
        }

        static func normalizedAlias(_ value: String) -> String? {
            let alias = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return alias.isEmpty ? nil : alias
        }

        static func normalizedAliases(_ values: [String]) -> [String] {
            var seen: Set<String> = []
            var aliases: [String] = []
            aliases.reserveCapacity(values.count)

            for value in values {
                guard let alias = self.normalizedAlias(value), !seen.contains(alias) else { continue }
                seen.insert(alias)
                aliases.append(alias)
            }

            return aliases
        }

        static func normalizedSymbol(_ value: String) -> String? {
            let symbol = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return symbol.isEmpty ? nil : symbol
        }
    }

    static func normalizedPunctuationDictionaryPrefix(_ value: String) -> String? {
        let prefix = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return prefix.isEmpty ? nil : prefix
    }

    var punctuationDictionaryPrefix: String {
        get {
            guard let stored = self.defaults.string(forKey: Keys.punctuationDictionaryPrefix),
                  let normalized = Self.normalizedPunctuationDictionaryPrefix(stored)
            else {
                return Self.defaultPunctuationDictionaryPrefix
            }
            return normalized
        }
        set {
            objectWillChange.send()
            self.defaults.set(
                Self.normalizedPunctuationDictionaryPrefix(newValue) ?? Self.defaultPunctuationDictionaryPrefix,
                forKey: Keys.punctuationDictionaryPrefix
            )
        }
    }

    var punctuationDictionaryRules: [PunctuationDictionaryRule] {
        get {
            guard let data = defaults.data(forKey: Keys.punctuationDictionaryRules),
                  let decoded = try? JSONDecoder().decode([PunctuationDictionaryRule].self, from: data)
            else {
                return Self.defaultPunctuationDictionaryRules
            }
            return decoded.compactMap { rule in
                let aliases = PunctuationDictionaryRule.normalizedAliases(rule.aliases)
                guard !aliases.isEmpty,
                      let symbol = PunctuationDictionaryRule.normalizedSymbol(rule.symbol)
                else {
                    return nil
                }
                return PunctuationDictionaryRule(id: rule.id, aliases: aliases, symbol: symbol)
            }
        }
        set {
            objectWillChange.send()
            let normalizedRules = newValue.compactMap { rule -> PunctuationDictionaryRule? in
                let aliases = PunctuationDictionaryRule.normalizedAliases(rule.aliases)
                guard !aliases.isEmpty,
                      let symbol = PunctuationDictionaryRule.normalizedSymbol(rule.symbol)
                else {
                    return nil
                }
                return PunctuationDictionaryRule(id: rule.id, aliases: aliases, symbol: symbol)
            }
            if let encoded = try? JSONEncoder().encode(normalizedRules) {
                self.defaults.set(encoded, forKey: Keys.punctuationDictionaryRules)
            }
        }
    }

    // MARK: - GAAV Mode

    var gaavLowercaseFirstLetterEnabled: Bool {
        get {
            self.defaults.object(forKey: Keys.gaavLowercaseFirstLetterEnabled) as? Bool ?? false
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.gaavLowercaseFirstLetterEnabled)
        }
    }

    var gaavRemoveTrailingPeriodEnabled: Bool {
        get {
            self.defaults.object(forKey: Keys.gaavRemoveTrailingPeriodEnabled) as? Bool ?? false
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.gaavRemoveTrailingPeriodEnabled)
        }
    }

    // MARK: - Continuous Dictation Mode

    var continuousDictationSpacingEnabled: Bool {
        get {
            self.defaults.object(forKey: Keys.continuousDictationSpacingEnabled) as? Bool ?? false
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.continuousDictationSpacingEnabled)
        }
    }

    var contextAwareCapitalizationEnabled: Bool {
        get {
            self.defaults.object(forKey: Keys.contextAwareCapitalizationEnabled) as? Bool ?? false
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.contextAwareCapitalizationEnabled)
        }
    }

    var needsDictationFormattingContext: Bool {
        self.continuousDictationSpacingEnabled || self.contextAwareCapitalizationEnabled
    }

    // MARK: - Media Playback Control

    /// When enabled, automatically pauses system media playback when transcription starts.
    /// Only resumes if VebeVoice was the one that paused it.
    var pauseMediaDuringTranscription: Bool {
        get { self.defaults.object(forKey: Keys.pauseMediaDuringTranscription) as? Bool ?? false }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.pauseMediaDuringTranscription)
        }
    }

    // MARK: - Custom Dictionary

    /// A custom dictionary entry that maps multiple misheard/alternate spellings to a correct replacement.
    /// For example: ["vibe voice", "vibe boys"] -> "VebeVoice"
    struct CustomDictionaryEntry: Codable, Identifiable, Hashable {
        let id: UUID
        /// Words/phrases to look for (case-insensitive matching)
        var triggers: [String]
        /// The correct replacement text
        var replacement: String

        init(triggers: [String], replacement: String) {
            self.id = UUID()
            self.triggers = triggers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            self.replacement = replacement
        }

        init(id: UUID, triggers: [String], replacement: String) {
            self.id = id
            self.triggers = triggers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            self.replacement = replacement
        }
    }

    var vocabularyBoostingEnabled: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.vocabularyBoostingEnabled)
            return value as? Bool ?? false
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.vocabularyBoostingEnabled)
            NotificationCenter.default.post(name: .parakeetVocabularyDidChange, object: nil)
        }
    }

    var automaticDictionaryLearningEnabled: Bool {
        get { self.defaults.object(forKey: Keys.automaticDictionaryLearningEnabled) as? Bool ?? true }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.automaticDictionaryLearningEnabled)
        }
    }

    /// Custom dictionary entries for word replacement
    var customDictionaryEntries: [CustomDictionaryEntry] {
        get {
            guard let data = defaults.data(forKey: Keys.customDictionaryEntries),
                  let decoded = try? JSONDecoder().decode([CustomDictionaryEntry].self, from: data)
            else {
                return []
            }
            return decoded
        }
        set {
            objectWillChange.send()
            if let encoded = try? JSONEncoder().encode(newValue) {
                self.defaults.set(encoded, forKey: Keys.customDictionaryEntries)
            }
        }
    }

    // MARK: - Speech Model (Unified ASR Model Selection)

    /// Unified speech recognition model selection.
    /// Replaces the old TranscriptionProviderOption + WhisperModelSize dual-setting.
    enum SpeechModel: String, CaseIterable, Identifiable, Codable {
        /// Temporarily disabled in UI/runtime while Parakeet word boosting work is prioritized.
        /// Flip to `true` in a future round to re-enable Qwen without deleting implementation.
        static let qwenPreviewEnabled = false

        // MARK: - FluidAudio Models (Apple Silicon Only)

        case parakeetTDT = "parakeet-tdt"
        case parakeetTDTv2 = "parakeet-tdt-v2"
        case parakeetRealtime = "parakeet-realtime"
        case qwen3Asr = "qwen3-asr"
        case cohereTranscribeSixBit = "cohere-transcribe-6bit"
        case nemotronOffline = "nemotron-3.5-offline"
        case nemotronStreaming = "nemotron-3.5-streaming"
        case nemotronStreaming320 = "nemotron-3.5-streaming-320"

        // MARK: - Apple Native

        case appleSpeech = "apple-speech"
        case appleSpeechAnalyzer = "apple-speech-analyzer"

        // MARK: - Whisper Models (Universal)

        case whisperTiny = "whisper-tiny"
        case whisperBase = "whisper-base"
        case whisperSmall = "whisper-small"
        case whisperMedium = "whisper-medium"
        case whisperLargeTurbo = "whisper-large-turbo"
        case whisperLarge = "whisper-large"

        var id: String {
            rawValue
        }

        // MARK: - Display Properties

        var displayName: String {
            switch self {
            case .parakeetTDT: return "Parakeet TDT v3 (Multilingual)"
            case .parakeetTDTv2: return "Parakeet TDT v2 (English Only)"
            case .parakeetRealtime: return "Parakeet Flash (Beta)"
            case .qwen3Asr: return "Qwen3 ASR (Beta)"
            case .cohereTranscribeSixBit: return "Cohere Transcribe"
            case .nemotronOffline: return "Nemotron 3.5 Multilingual"
            case .nemotronStreaming: return "Nemotron Speech 3.5 - Ultra Fast Low Latency"
            case .nemotronStreaming320: return "Nemotron Speech 3.5 - Ultra Fast Low Latency"
            case .appleSpeech: return "Apple ASR Legacy"
            case .appleSpeechAnalyzer: return "Apple Speech - macOS 26+"
            case .whisperTiny: return "Whisper Tiny"
            case .whisperBase: return "Whisper Base"
            case .whisperSmall: return "Whisper Small"
            case .whisperMedium: return "Whisper Medium"
            case .whisperLargeTurbo: return "Whisper Large Turbo"
            case .whisperLarge: return "Whisper Large"
            }
        }

        var languageSupport: String {
            switch self {
            case .parakeetTDT:
                return "25 Languages"
            case .parakeetTDTv2: return "English Only (Higher Accuracy)"
            case .parakeetRealtime: return "English Only (Live Streaming)"
            case .qwen3Asr: return "30 Languages"
            case .cohereTranscribeSixBit: return "14 Languages (Select Manually)"
            case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320: return "Around 40 Languages"
            case .appleSpeech: return "System Languages"
            case .appleSpeechAnalyzer: return "EN, ES, FR, DE, IT, JA, KO, PT, ZH"
            case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
                return "99 Languages"
            }
        }

        var downloadSize: String {
            switch self {
            case .parakeetTDT: return "~460.9 MiB"
            case .parakeetTDTv2: return "~442.9 MiB"
            case .parakeetRealtime: return "~428.4 MiB"
            case .qwen3Asr: return "~2.0 GiB"
            case .cohereTranscribeSixBit: return "~1.54 GiB"
            case .nemotronOffline: return "~530.8 MiB"
            case .nemotronStreaming: return "~668.2 MiB"
            case .nemotronStreaming320: return "~668.2 MiB"
            case .appleSpeech: return "Built-in"
            case .appleSpeechAnalyzer: return "Built-in"
            case .whisperTiny: return "~43.9 MiB"
            case .whisperBase: return "~81.0 MiB"
            case .whisperSmall: return "~257.3 MiB"
            case .whisperMedium: return "~793.0 MiB"
            case .whisperLargeTurbo: return "~845.3 MiB"
            case .whisperLarge: return "~1.55 GiB"
            }
        }

        var expectedDownloadBytes: Int64 {
            switch self {
            case .parakeetTDT: return 483_288_717
            case .parakeetTDTv2: return 464_421_712
            case .parakeetRealtime: return 449_190_189
            case .qwen3Asr: return 2000 * 1024 * 1024
            case .cohereTranscribeSixBit: return 1_650_748_785
            case .nemotronOffline: return 556_552_620
            case .nemotronStreaming, .nemotronStreaming320: return 700_685_415
            case .whisperTiny: return 45_981_088
            case .whisperBase: return 84_962_880
            case .whisperSmall: return 269_751_136
            case .whisperMedium: return 831_538_144
            case .whisperLargeTurbo: return 886_381_824
            case .whisperLarge: return 1_668_741_440
            case .appleSpeech, .appleSpeechAnalyzer: return 0
            }
        }

        var requiresAppleSilicon: Bool {
            switch self {
            case .parakeetTDT, .parakeetTDTv2, .parakeetRealtime, .qwen3Asr, .cohereTranscribeSixBit, .nemotronOffline, .nemotronStreaming, .nemotronStreaming320: return true
            default: return false
            }
        }

        var isWhisperModel: Bool {
            switch self {
            case .parakeetTDT, .parakeetTDTv2, .parakeetRealtime, .qwen3Asr, .cohereTranscribeSixBit, .nemotronOffline, .nemotronStreaming, .nemotronStreaming320, .appleSpeech, .appleSpeechAnalyzer: return false
            default: return true
            }
        }

        /// The GGUF filename for transcribe.cpp Whisper models.
        var whisperModelFile: String? {
            switch self {
            case .whisperTiny: return "whisper-tiny-Q8_0.gguf"
            case .whisperBase: return "whisper-base-Q8_0.gguf"
            case .whisperSmall: return "whisper-small-Q8_0.gguf"
            case .whisperMedium: return "whisper-medium-Q8_0.gguf"
            case .whisperLargeTurbo: return "whisper-large-v3-turbo-Q8_0.gguf"
            case .whisperLarge: return "whisper-large-v3-Q8_0.gguf"
            default: return nil
            }
        }

        /// The short model name for whisper.cpp internal usage
        var whisperModelName: String? {
            switch self {
            case .whisperTiny: return "tiny"
            case .whisperBase: return "base"
            case .whisperSmall: return "small"
            case .whisperMedium: return "medium"
            case .whisperLargeTurbo: return "large-v3-turbo"
            case .whisperLarge: return "large-v3"
            default: return nil
            }
        }

        // MARK: - Architecture Filtering

        /// Requires macOS 26 (Tahoe) or later
        var requiresMacOS26: Bool {
            switch self {
            case .appleSpeechAnalyzer: return true
            default: return false
            }
        }

        /// Requires macOS 15 or later.
        var requiresMacOS15: Bool {
            switch self {
            case .qwen3Asr, .cohereTranscribeSixBit: return true
            default: return false
            }
        }

        /// Returns models available for the current Mac's architecture and OS
        static var availableModels: [SpeechModel] {
            allCases.filter { model in
                if model == .whisperLargeTurbo, !CPUArchitecture.isAppleSilicon {
                    return false
                }
                if model == .whisperLarge, !CPUArchitecture.isAppleSilicon {
                    return false
                }
                if model == .qwen3Asr, !Self.qwenPreviewEnabled {
                    return false
                }
                if model == .nemotronStreaming320 {
                    return false
                }
                // Filter by Apple Silicon requirement
                if model.requiresAppleSilicon, !CPUArchitecture.isAppleSilicon {
                    return false
                }
                // Filter by macOS 15 requirement
                if model.requiresMacOS15, #unavailable(macOS 15.0) {
                    return false
                }
                // Filter by macOS 26 requirement
                if model.requiresMacOS26 {
                    if #available(macOS 26.0, *) {
                        return true
                    } else {
                        return false
                    }
                }
                return true
            }
        }

        /// Default model for the current architecture
        static var defaultModel: SpeechModel {
            CPUArchitecture.isAppleSilicon ? .parakeetTDT : .whisperBase
        }

        // MARK: - UI Card Metadata

        /// Human-readable marketing name for the card UI
        var humanReadableName: String {
            switch self {
            case .parakeetTDT: return "Blazing Fast - Multilingual"
            case .parakeetTDTv2: return "Blazing Fast - English"
            case .parakeetRealtime: return "Flash Dictation"
            case .qwen3Asr: return "Qwen3 - Multilingual"
            case .cohereTranscribeSixBit: return "Cohere - High Accuracy"
            case .nemotronOffline: return "Nemotron 3.5 Multilingual"
            case .nemotronStreaming: return "Nemotron Speech 3.5 - Ultra Fast Low Latency"
            case .nemotronStreaming320: return "Nemotron Speech 3.5 - Ultra Fast Low Latency"
            case .appleSpeech: return "Apple ASR Legacy"
            case .appleSpeechAnalyzer: return "Apple Speech - macOS 26+"
            case .whisperTiny: return "Fast & Light"
            case .whisperBase: return "Standard Choice"
            case .whisperSmall: return "Balanced Speed & Accuracy"
            case .whisperMedium: return "Medium Quality"
            case .whisperLargeTurbo: return "Higher Quality but Faster"
            case .whisperLarge: return "Maximum Accuracy"
            }
        }

        /// One-line description for the card UI
        var cardDescription: String {
            switch self {
            case .parakeetTDT:
                return "Fast multilingual transcription. Supports Bulgarian, Croatian, Czech, Danish, " +
                    "Dutch, English, Estonian, Finnish, French, German, Greek, Hungarian, Italian, " +
                    "Latvian, Lithuanian, Maltese, Polish, Portuguese, Romanian, Russian, Slovak, " +
                    "Slovenian, Spanish, Swedish, and Ukrainian."
            case .parakeetTDTv2:
                return "Optimized for English accuracy and fastest transcription."
            case .parakeetRealtime:
                return "English-only streaming local dictation with low-latency partial text and end-of-utterance detection."
            case .qwen3Asr:
                return "Qwen3 multilingual ASR via FluidAudio. Higher quality, heavier memory footprint."
            case .cohereTranscribeSixBit:
                return "High-accuracy multilingual transcription. Select the language manually before dictation for best results."
            case .nemotronOffline:
                return "Slower but more accurate NVIDIA Nemotron 3.5 transcription. Supports 40 language-locales with auto or manual language selection."
            case .nemotronStreaming:
                return "NVIDIA Nemotron 3.5 streaming-capable transcription. Supports 40 language-locales with auto or manual language selection."
            case .nemotronStreaming320:
                return "NVIDIA Nemotron 3.5 streaming-capable transcription. Supports 40 language-locales with auto or manual language selection."
            case .appleSpeech:
                return "Built-in macOS speech recognition. No model download required."
            case .appleSpeechAnalyzer:
                return "Advanced and modern on-device recognition for newer macOS devices."
            case .whisperTiny:
                return "Minimal resource usage. Best for older Macs or battery life."
            case .whisperBase:
                return "Good balance of speed and accuracy. Works on any Mac."
            case .whisperSmall:
                return "Better accuracy than Base. Moderate resource usage."
            case .whisperMedium:
                return "High accuracy for demanding tasks. Requires more memory."
            case .whisperLargeTurbo:
                return "Near-maximum accuracy with optimized speed."
            case .whisperLarge:
                return "Best possible accuracy. Large download and memory usage."
            }
        }

        /// Minimum recommended RAM in GB for this model to run safely
        var requiredMemoryGB: Double {
            switch self {
            case .parakeetTDT, .parakeetTDTv2, .parakeetRealtime:
                return 4.0
            case .qwen3Asr:
                return 8.0
            case .cohereTranscribeSixBit:
                return 8.0
            case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
                return 8.0
            case .appleSpeech, .appleSpeechAnalyzer:
                return 2.0 // Built-in, minimal overhead
            case .whisperTiny:
                return 2.0
            case .whisperBase:
                return 3.0
            case .whisperSmall:
                return 4.0
            case .whisperMedium:
                return 5.0
            case .whisperLargeTurbo:
                return 6.0
            case .whisperLarge:
                return 8.0
            }
        }

        /// Warning text for models with high memory requirements, nil if no warning needed
        var memoryWarning: String? {
            switch self {
            case .qwen3Asr:
                return "⚠️ Requires 8GB+ RAM. Best on newer Apple Silicon Macs."
            case .whisperLarge:
                return "⚠️ Requires 10GB+ RAM. May crash on systems with limited memory."
            case .whisperLargeTurbo:
                return "⚠️ Requires 8GB+ RAM. May be unstable on some systems."
            case .whisperMedium:
                return "Requires 6GB+ RAM for stable operation."
            default:
                return nil
            }
        }

        /// Speed rating (1-5, higher is faster)
        var speedRating: Int {
            switch self {
            case .parakeetTDT: return 5
            case .parakeetTDTv2: return 5
            case .parakeetRealtime: return 5
            case .qwen3Asr: return 3
            case .cohereTranscribeSixBit: return 3
            case .nemotronOffline: return 3
            case .nemotronStreaming, .nemotronStreaming320: return 4
            case .appleSpeech: return 4
            case .appleSpeechAnalyzer: return 4
            case .whisperTiny: return 4
            case .whisperBase: return 4
            case .whisperSmall: return 3
            case .whisperMedium: return 2
            case .whisperLargeTurbo: return 3
            case .whisperLarge: return 1
            }
        }

        /// Accuracy rating (1-5, higher is more accurate)
        var accuracyRating: Int {
            switch self {
            case .parakeetTDT: return 5
            case .parakeetTDTv2: return 5
            case .parakeetRealtime: return 4
            case .qwen3Asr: return 4
            case .cohereTranscribeSixBit: return 5
            case .nemotronOffline: return 5
            case .nemotronStreaming, .nemotronStreaming320: return 4
            case .appleSpeech: return 4
            case .appleSpeechAnalyzer: return 4
            case .whisperTiny: return 2
            case .whisperBase: return 3
            case .whisperSmall: return 4
            case .whisperMedium: return 4
            case .whisperLargeTurbo: return 5
            case .whisperLarge: return 5
            }
        }

        /// Exact speed percentage (0.0 - 1.0) for the liquid bars
        var speedPercent: Double {
            switch self {
            case .parakeetTDT: return 1.0
            case .parakeetTDTv2: return 1.0
            case .parakeetRealtime: return 1.0
            case .qwen3Asr: return 0.45
            case .cohereTranscribeSixBit: return 0.85
            case .nemotronOffline: return 0.85
            case .nemotronStreaming, .nemotronStreaming320: return 1.0
            case .appleSpeech: return 0.60
            case .appleSpeechAnalyzer: return 0.85
            case .whisperTiny: return 0.90
            case .whisperBase: return 0.80
            case .whisperSmall: return 0.60
            case .whisperMedium: return 0.40
            case .whisperLargeTurbo: return 0.65
            case .whisperLarge: return 0.20
            }
        }

        /// Exact accuracy percentage (0.0 - 1.0) for the liquid bars
        var accuracyPercent: Double {
            switch self {
            case .parakeetTDT: return 0.92
            case .parakeetTDTv2: return 0.96
            case .parakeetRealtime: return 0.75
            case .qwen3Asr: return 0.90
            case .cohereTranscribeSixBit: return 0.98
            case .nemotronOffline: return 0.90
            case .nemotronStreaming, .nemotronStreaming320: return 0.85
            case .appleSpeech: return 0.60
            case .appleSpeechAnalyzer: return 0.80
            case .whisperTiny: return 0.40
            case .whisperBase: return 0.60
            case .whisperSmall: return 0.70
            case .whisperMedium: return 0.80
            case .whisperLargeTurbo: return 0.95
            case .whisperLarge: return 1.00
            }
        }

        /// Optional badge text for the card (e.g., "VebeVoice Pick")
        var badgeText: String? {
            switch self {
            case .parakeetTDT: return "VebeVoice Pick"
            case .parakeetTDTv2: return "VebeVoice Pick"
            case .parakeetRealtime: return "Beta"
            case .qwen3Asr: return "Beta"
            case .cohereTranscribeSixBit: return "New"
            case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320: return "New + Beta"
            case .appleSpeechAnalyzer: return "New"
            default: return nil
            }
        }

        /// Optimization level for Apple Silicon (for display)
        var appleSiliconOptimized: Bool {
            switch self {
            case .parakeetTDT, .parakeetTDTv2, .parakeetRealtime, .qwen3Asr, .cohereTranscribeSixBit, .nemotronOffline, .nemotronStreaming, .nemotronStreaming320, .appleSpeechAnalyzer:
                return true
            default:
                return false
            }
        }

        /// Whether this model supports real-time streaming/chunk processing.
        /// Large Whisper models are too slow for streaming, so they only do final transcription on stop.
        var supportsStreaming: Bool {
            switch self {
            case .qwen3Asr, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
                return false // Too slow for real-time chunk processing
            default:
                return true // All other models support streaming
            }
        }

        /// Preview update cadence for real-time transcription.
        /// Models without native incremental decoding should use a slower interval.
        var streamingPreviewIntervalSeconds: Double {
            switch self {
            case .parakeetRealtime:
                return 0.2
            case .nemotronStreaming, .nemotronStreaming320:
                return 0.32
            case .cohereTranscribeSixBit:
                return 1.0
            default:
                return 0.6
            }
        }

        /// Minimum audio required before attempting a preview decode.
        /// Cohere performs better with a slightly larger prefix than the default 1 second.
        var minimumStreamingPreviewSeconds: Double {
            switch self {
            case .parakeetRealtime:
                return 0.2
            case .nemotronStreaming, .nemotronStreaming320:
                return 0.64
            case .cohereTranscribeSixBit:
                return 1.5
            default:
                return 1.0
            }
        }

        /// Provider category for tab grouping
        enum Provider: String, CaseIterable {
            case nvidia = "NVIDIA"
            case apple = "Apple"
            case openai = "OpenAI"
            case qwen = "Qwen"
            case cohere = "Cohere"
        }

        /// Which provider this model belongs to
        var provider: Provider {
            switch self {
            case .parakeetTDT, .parakeetTDTv2, .parakeetRealtime, .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
                return .nvidia
            case .appleSpeech, .appleSpeechAnalyzer:
                return .apple
            case .qwen3Asr:
                return .qwen
            case .cohereTranscribeSixBit:
                return .cohere
            case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
                return .openai
            }
        }

        /// Whether this model is built-in or already downloaded on disk
        var isInstalled: Bool {
            switch self {
            case .appleSpeech, .appleSpeechAnalyzer:
                return true
            case .parakeetTDT:
                #if canImport(FluidAudio)
                return Self.parakeetModelsExist(version: .v3)
                #else
                return false
                #endif
            case .parakeetTDTv2:
                #if canImport(FluidAudio)
                return Self.parakeetModelsExist(version: .v2)
                #else
                return false
                #endif
            case .parakeetRealtime:
                #if canImport(FluidAudio)
                return Self.parakeetRealtimeModelsExist()
                #else
                return false
                #endif
            case .qwen3Asr:
                #if canImport(FluidAudio) && ENABLE_QWEN
                if #available(macOS 15.0, *) {
                    return Qwen3AsrModels.modelsExist(at: Qwen3AsrModels.defaultCacheDirectory())
                }
                return false
                #else
                return false
                #endif
            case .cohereTranscribeSixBit:
                guard
                    let spec = self.externalCoreMLSpec,
                    let directory = SettingsStore.shared.externalCoreMLArtifactsDirectory(for: self)
                else {
                    return false
                }
                return spec.validatesInstalledArtifacts(at: directory)
            case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
                let hint: String
                switch self {
                case .nemotronOffline:
                    hint = "nemotron-3.5-asr-offline-6bit-CoreML"
                default:
                    hint = "nemotron-3.5-asr-streaming320-int8-CoreML"
                }
                let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                    .appendingPathComponent(hint, isDirectory: true)
                #if arch(arm64)
                return directory.map { NemotronProvider.artifactsAreComplete(at: $0) } ?? false
                #else
                return false
                #endif
            default:
                // Whisper models
                guard let whisperFile = self.whisperModelFile else { return false }
                let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                    .appendingPathComponent("WhisperModels")
                let modelURL = directory?.appendingPathComponent(whisperFile)
                guard
                    let modelURL,
                    let attributes = try? FileManager.default.attributesOfItem(atPath: modelURL.path),
                    let size = attributes[.size] as? NSNumber,
                    size.int64Value > 0
                else {
                    return false
                }
                return size.int64Value == self.expectedDownloadBytes
            }
        }

        #if canImport(FluidAudio)
        private static func parakeetModelsExist(version: AsrModelVersion) -> Bool {
            let directory = AsrModels.defaultCacheDirectory(for: version)
            let vocabulary = directory.appendingPathComponent(ModelNames.ASR.vocabularyFile)
            guard
                AsrModels.modelsExist(at: directory, version: version),
                HuggingFaceModelDownloader.artifactIsComplete(at: vocabulary, isDirectory: false)
            else {
                return false
            }

            return AsrModels.requiredModelNames.allSatisfy { modelName in
                HuggingFaceModelDownloader.artifactIsComplete(
                    at: directory.appendingPathComponent(modelName, isDirectory: true),
                    isDirectory: true
                )
            }
        }

        private static func parakeetRealtimeModelsExist() -> Bool {
            let modelsDirectory = AsrModels.defaultCacheDirectory().deletingLastPathComponent()
            let modelDirectory = modelsDirectory
                .appendingPathComponent("parakeet-eou-streaming", isDirectory: true)
                .appendingPathComponent(Repo.parakeetEou160.folderName, isDirectory: true)

            return ModelNames.ParakeetEOU.requiredModels.allSatisfy { modelName in
                let artifact = modelDirectory.appendingPathComponent(modelName)
                return HuggingFaceModelDownloader.artifactIsComplete(
                    at: artifact,
                    isDirectory: modelName.hasSuffix(".mlmodelc")
                )
            }
        }
        #endif

        /// Brand/provider name for the model (NVIDIA, Apple, OpenAI)
        var brandName: String {
            switch self {
            case .parakeetTDT, .parakeetTDTv2, .parakeetRealtime, .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
                return "NVIDIA"
            case .qwen3Asr:
                return "Qwen"
            case .cohereTranscribeSixBit:
                return "Cohere"
            case .appleSpeech, .appleSpeechAnalyzer:
                return "Apple"
            case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
                return "OpenAI"
            }
        }

        /// Whether this model uses Apple's SF Symbol for branding (apple.logo)
        var usesAppleLogo: Bool {
            switch self {
            case .appleSpeech, .appleSpeechAnalyzer: return true
            default: return false
            }
        }

        /// Brand color for the provider badge
        var brandColorHex: String {
            switch self {
            case .parakeetTDT, .parakeetTDTv2, .parakeetRealtime, .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
                return "#76B900"
            case .qwen3Asr:
                return "#E67E22"
            case .cohereTranscribeSixBit:
                return "#FA6B3C"
            case .appleSpeech, .appleSpeechAnalyzer:
                return "#A2AAAD" // Apple Gray
            case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
                return "#10A37F" // OpenAI Teal
            }
        }
    }

}

// swiftlint:enable type_body_length

private extension SettingsStore {
    /// Keys
    enum Keys {
        static let showMainWindowAtLoginLaunch = "ShowMainWindowAtLoginLaunch"
        static let enableDebugLogs = "EnableDebugLogs"
        static let primaryDictationShortcutsKey = "PrimaryDictationShortcuts"
        static let preferredInputDeviceUID = "PreferredInputDeviceUID"
        static let preferredOutputDeviceUID = "PreferredOutputDeviceUID"
        static let microphoneSelectionMode = "MicrophoneSelectionMode"
        static let systemInputDeviceUIDBeforeManual = "SystemInputDeviceUIDBeforeManual"
        static let visualizerNoiseThreshold = "VisualizerNoiseThreshold"
        static let showInDock = "ShowInDock"
        static let accentColorOption = "AccentColorOption"
        static let themePreference = "ThemePreference"
        static let transcriptionStartSound = "TranscriptionStartSound"
        static let transcriptionSoundVolume = "TranscriptionSoundVolume"
        static let transcriptionSoundIndependentVolume = "TranscriptionSoundIndependentVolume"
        static let hotkeyMode = "HotkeyMode"
        static let enableStreamingPreview = "EnableStreamingPreview"
        static let experimentalDirectAudioCaptureEnabled = "ExperimentalDirectAudioCaptureEnabled"
        static let directAudioCaptureConsecutiveFailures = "DirectAudioCaptureConsecutiveFailures"
        static let copyTranscriptionToClipboard = "CopyTranscriptionToClipboard"
        static let textInsertionMode = "TextInsertionMode"
        static let playgroundUsed = "PlaygroundUsed"
        static let firstOpenAt = "FirstOpenAt"
        static let onboardingCompleted = "OnboardingCompleted"
        static let manualOnboardingResetRequested = "ManualOnboardingResetRequested"
        static let manualOnboardingResetRequestedAt = "ManualOnboardingResetRequestedAt"
        static let onboardingCurrentStep = "OnboardingCurrentStep"
        static let onboardingPlaygroundValidated = "OnboardingPlaygroundValidated"
        static let onboardingPlaygroundSkipped = "OnboardingPlaygroundSkipped"
        static let onboardingSelectedLanguageID = "OnboardingSelectedLanguageID"

        static let cancelRecordingHotkeyShortcut = "CancelRecordingHotkeyShortcut"
        static let pasteLastTranscriptionHotkeyShortcut = "PasteLastTranscriptionHotkeyShortcut"
        static let pasteLastTranscriptionShortcutEnabled = "PasteLastTranscriptionShortcutEnabled"

        // Prompt Mode Keys (Transcribe with Prompt)
        static let promptModeHotkeyShortcut = "PromptModeHotkeyShortcut"
        static let promptModeShortcutEnabled = "PromptModeShortcutEnabled"

        // Stats Keys
        static let userTypingWPM = "UserTypingWPM"
        static let saveTranscriptionHistory = "SaveTranscriptionHistory"
        static let saveAudioWithTranscriptionHistory = "SaveAudioWithTranscriptionHistory"
        static let audioHistoryBudgetGB = "AudioHistoryBudgetGB"

        // Filler Words
        static let fillerWords = "FillerWords"
        static let removeFillerWordsEnabled = "RemoveFillerWordsEnabled"
        static let autoConvertPunctuationEnabled = "AutoConvertPunctuationEnabled"
        static let literalDictationFormattingEnabled = "LiteralDictationFormattingEnabled"
        static let punctuationDictionaryPrefix = "PunctuationDictionaryPrefix"
        static let punctuationDictionaryRules = "PunctuationDictionaryRules"

        /// GAAV Mode (removes capitalization and trailing punctuation)
        static let gaavLowercaseFirstLetterEnabled = "GAAVLowercaseFirstLetterEnabled"
        static let gaavRemoveTrailingPeriodEnabled = "GAAVRemoveTrailingPeriodEnabled"

        /// Continuous Dictation Mode (append trailing space + smart caps for chaining)
        static let continuousDictationSpacingEnabled = "ContinuousDictationSpacingEnabled"
        static let contextAwareCapitalizationEnabled = "ContextAwareCapitalizationEnabled"

        // Custom Dictionary
        static let customDictionaryEntries = "CustomDictionaryEntries"
        static let automaticDictionaryLearningEnabled = "AutomaticDictionaryLearningEnabled"
        static let vocabularyBoostingEnabled = "VocabularyBoostingEnabled"

        // Speech Model
        static let selectedSpeechModel = "SelectedSpeechModel"
        static let selectedCohereLanguage = "SelectedCohereLanguage"
        static let selectedNemotronLanguage = "SelectedNemotronLanguage"
        static let selectedAppleSpeechLocaleIdentifier = "SelectedAppleSpeechLocaleIdentifier"
        static let externalCoreMLArtifactsDirectories = "ExternalCoreMLArtifactsDirectories"

        // Overlay
        static let overlayBottomOffset = "OverlayBottomOffset"
        static let overlaySize = "OverlaySize"
        static let transcriptionPreviewCharLimit = "TranscriptionPreviewCharLimit"

        /// Media Playback Control
        static let pauseMediaDuringTranscription = "PauseMediaDuringTranscription"

        /// Streak Settings
        static let weekendsDontBreakStreak = "WeekendsDontBreakStreak"
    }
}

extension SettingsStore {
    enum TextInsertionMode: String, CaseIterable, Identifiable, Codable {
        case standard
        case reliablePaste

        var id: String {
            self.rawValue
        }

        var displayName: String {
            switch self {
            case .standard:
                return "Clipboard Free Insert"
            case .reliablePaste:
                return "Clipboard Paste"
            }
        }

        var description: String {
            switch self {
            case .standard:
                return "Fastest path. Inserts text without changing the clipboard, with paste fallback if direct insertion is unavailable."
            case .reliablePaste:
                return "Compatibility path. Uses a temporary clipboard paste, so clipboard history apps may briefly record dictated text."
            }
        }
    }

    var textInsertionMode: TextInsertionMode {
        get {
            guard let raw = self.defaults.string(forKey: Keys.textInsertionMode),
                  let mode = TextInsertionMode(rawValue: raw)
            else {
                return .standard
            }
            return mode
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.textInsertionMode)
        }
    }

}

extension SettingsStore.SpeechModel {
    var supportedLanguageCodes: String? {
        switch self {
        case .parakeetTDT:
            return "BG, HR, CS, DA, NL, EN, ET, FI, FR, DE, EL, HU, IT, LV, LT, MT, PL, PT, RO, SK, SL, ES, SV, RU, UK"
        case .parakeetRealtime:
            return "EN"
        case .cohereTranscribeSixBit:
            return "AR, DE, EL, EN, ES, FR, IT, JA, KO, NL, PL, PT, VI, ZH"
        case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
            return "40 language-locales"
        case .appleSpeechAnalyzer:
            return "EN, ES, FR, DE, IT, JA, KO, PT, ZH"
        default:
            return nil
        }
    }

    var supportedLanguageNames: String? {
        switch self {
        case .parakeetTDT:
            return """
            Bulgarian, Croatian, Czech, Danish, Dutch, English, Estonian, Finnish, French, German, Greek, Hungarian, Italian, Latvian, Lithuanian, Maltese, Polish, Portuguese, Romanian, Slovak, Slovenian, Spanish, Swedish, Russian, and Ukrainian
            """
        case .cohereTranscribeSixBit:
            return "Arabic, German, Greek, English, Spanish, French, Italian, Japanese, Korean, Dutch, Polish, Portuguese, Vietnamese, and Mandarin Chinese"
        case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
            return "Spanish, Italian, Portuguese, Hindi, Korean, English, German, French, Russian, Turkish, Vietnamese, Dutch, Japanese, Arabic, " +
                "Ukrainian; Polish, Norwegian Bokmal, Finnish, Mandarin, Czech, Bulgarian, Slovak, Swedish, Croatian, Romanian, Estonian, " +
                "Danish, and Hungarian are Alpha; Greek, Hebrew, Lithuanian, Slovenian, Latvian, Maltese, Thai, and Norwegian Nynorsk are Experimental."
        default:
            return nil
        }
    }
}

extension SettingsStore {
    enum CohereLanguage: String, CaseIterable, Identifiable, Codable {
        case arabic = "ar"
        case german = "de"
        case greek = "el"
        case english = "en"
        case spanish = "es"
        case french = "fr"
        case italian = "it"
        case japanese = "ja"
        case korean = "ko"
        case dutch = "nl"
        case polish = "pl"
        case portuguese = "pt"
        case vietnamese = "vi"
        case mandarinChinese = "zh"

        var id: String {
            self.rawValue
        }

        var displayName: String {
            switch self {
            case .arabic: return "Arabic"
            case .german: return "German"
            case .greek: return "Greek"
            case .english: return "English"
            case .spanish: return "Spanish"
            case .french: return "French"
            case .italian: return "Italian"
            case .japanese: return "Japanese"
            case .korean: return "Korean"
            case .dutch: return "Dutch"
            case .polish: return "Polish"
            case .portuguese: return "Portuguese"
            case .vietnamese: return "Vietnamese"
            case .mandarinChinese: return "Mandarin Chinese"
            }
        }

        var tokenString: String {
            "<|\(self.rawValue)|>"
        }
    }

    // MARK: - Unified Speech Model Selection

    /// The selected speech recognition model.
    /// This unified setting replaces the old TranscriptionProviderOption + WhisperModelSize combination.
    var selectedSpeechModel: SpeechModel {
        get {
            // Check if already using new system
            if let rawValue = defaults.string(forKey: Keys.selectedSpeechModel),
               let model = SpeechModel(rawValue: rawValue)
            {
                // If Qwen was previously selected, transparently fall back while preview is disabled.
                if model == .qwen3Asr, !SpeechModel.qwenPreviewEnabled {
                    return SpeechModel.defaultModel
                }
                if model == .nemotronStreaming320 {
                    return .nemotronStreaming
                }
                let requiresAppleSiliconWhisper = model == .whisperLargeTurbo || model == .whisperLarge
                if requiresAppleSiliconWhisper, !CPUArchitecture.isAppleSilicon {
                    return .whisperBase
                }
                // Validate model is available on this architecture
                if model.requiresAppleSilicon && !CPUArchitecture.isAppleSilicon {
                    return .whisperBase
                }
                if model.requiresMacOS15, #unavailable(macOS 15.0) {
                    return .whisperBase
                }
                if model.requiresMacOS26, #unavailable(macOS 26.0) {
                    return .whisperBase
                }
                return model
            }

            return SpeechModel.defaultModel
        }
        set {
            objectWillChange.send()
            let model = newValue == .nemotronStreaming320 ? SpeechModel.nemotronStreaming : newValue
            self.defaults.set(model.rawValue, forKey: Keys.selectedSpeechModel)
        }
    }

    var selectedCohereLanguage: CohereLanguage {
        get {
            if let rawValue = self.defaults.string(forKey: Keys.selectedCohereLanguage),
               let language = CohereLanguage(rawValue: rawValue)
            {
                return language
            }
            return .english
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.selectedCohereLanguage)
        }
    }

    var selectedNemotronLanguage: NemotronLanguage {
        get {
            if let rawValue = self.defaults.string(forKey: Keys.selectedNemotronLanguage),
               let language = NemotronLanguage.supportedLanguage(rawValue: rawValue)
            {
                return language
            }
            return .english
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.selectedNemotronLanguage)
        }
    }

    func externalCoreMLArtifactsDirectory(for model: SpeechModel) -> URL? {
        guard let spec = model.externalCoreMLSpec else { return nil }
        let paths = self.defaults.dictionary(forKey: Keys.externalCoreMLArtifactsDirectories) as? [String: String] ?? [:]
        if let storedPath = paths[model.rawValue], storedPath.isEmpty == false {
            return URL(fileURLWithPath: storedPath, isDirectory: true)
        }

        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let fallback = cachesDirectory?.appendingPathComponent(spec.artifactFolderHint, isDirectory: true)
        guard let fallback else { return nil }
        if FileManager.default.fileExists(atPath: fallback.path) {
            return fallback
        }
        return nil
    }

    func setExternalCoreMLArtifactsDirectory(_ directory: URL?, for model: SpeechModel) {
        guard model.requiresExternalArtifacts else { return }
        objectWillChange.send()
        var paths = self.defaults.dictionary(forKey: Keys.externalCoreMLArtifactsDirectories) as? [String: String] ?? [:]
        if let directory {
            paths[model.rawValue] = directory.standardizedFileURL.path
        } else {
            paths.removeValue(forKey: model.rawValue)
        }
        self.defaults.set(paths, forKey: Keys.externalCoreMLArtifactsDirectories)
    }

}
