//
//  NotchOverlayManager.swift
//  VebeVoice
//
//  Created by Assistant
//

import AppKit
import Combine
import SwiftUI

// MARK: - Overlay Mode

enum OverlayMode: String {
    case dictation = "Dictation"
}

@MainActor
final class NotchOverlayManager {
    static let shared = NotchOverlayManager()

    private var currentMode: OverlayMode = .dictation

    /// Store last audio publisher for re-showing during processing
    private var lastAudioPublisher: AnyPublisher<CGFloat, Never>?

    /// Track if bottom overlay is visible
    private(set) var isBottomOverlayVisible: Bool = false

    // Generation counter to track show/hide cycles and prevent race conditions
    // Uses UInt64 to avoid overflow concerns in long-running sessions
    private var generation: UInt64 = 0
    private var isHideInProgress = false
    private var hideWaiters: [CheckedContinuation<Void, Never>] = []

    /// Track pending retry task for cancellation
    private var pendingRetryTask: Task<Void, Never>?

    // Cancel shortcut monitors for dismissing the overlay
    private var globalEscapeMonitor: Any?
    private var localEscapeMonitor: Any?

    private static let transientOverlayStatusTexts: Set<String> = [
        "Transcribing",
    ]

    private init() {
        self.setupEscapeKeyMonitors()
    }

    deinit {
        if let monitor = globalEscapeMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localEscapeMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// Setup cancel shortcut monitors - both global (other apps) and local (our app)
    private func setupEscapeKeyMonitors() {
        let escapeHandler: (NSEvent) -> NSEvent? = { [weak self] event in
            guard SettingsStore.shared.cancelRecordingHotkeyShortcut.matches(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags
            ) else { return event }

            Task { @MainActor in
                guard self != nil else { return }
                NotchContentState.shared.onCancelRequested?()
            }
            return nil // Consume the event
        }

        // Global monitor - catches the cancel shortcut when OTHER apps have focus
        self.globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            _ = escapeHandler(event)
        }
    }

    func show(audioLevelPublisher: AnyPublisher<CGFloat, Never>, mode: OverlayMode) {
        Self.overlayBench("show_called mode=\(mode.rawValue) bottomVisible=\(self.isBottomOverlayVisible)")

        // Cancel any pending retry operations
        self.pendingRetryTask?.cancel()
        self.pendingRetryTask = nil

        self.showInternal(audioLevelPublisher: audioLevelPublisher, mode: mode)
    }

    private func showInternal(audioLevelPublisher: AnyPublisher<CGFloat, Never>, mode: OverlayMode) {
        Self.overlayBench("show_internal_enter mode=\(mode.rawValue)")

        // Store for potential re-show during processing
        self.lastAudioPublisher = audioLevelPublisher

        // Start monitoring active app changes (updates icon in real-time)
        ActiveAppMonitor.shared.startMonitoring()

        Self.overlayBench("show_internal_route target=bottom")
        self.showBottomOverlay(audioLevelPublisher: audioLevelPublisher, mode: mode)
    }

    /// Show bottom overlay
    private func showBottomOverlay(audioLevelPublisher: AnyPublisher<CGFloat, Never>, mode: OverlayMode) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        Self.overlayBench("bottom_route_start mode=\(mode.rawValue)")
        self.generation &+= 1

        self.lastAudioPublisher = audioLevelPublisher
        self.currentMode = self.normalizedOverlayMode(mode)

        BottomOverlayWindowController.shared.show(audioPublisher: audioLevelPublisher, mode: self.currentMode)
        self.isBottomOverlayVisible = true
        Self.overlayBench("bottom_route_return elapsedMs=\(Self.elapsedMs(since: startedAt))")
    }

    func hide() {
        guard !self.isHideInProgress else { return }
        self.isHideInProgress = true
        self.generation &+= 1
        let currentGeneration = self.generation
        Task { [weak self] in
            guard let self else { return }
            await self.performHideAndWait(generation: currentGeneration)
            self.completeHideOperation()
        }
    }

    /// Dismisses the active recording overlay and returns only after its visual
    /// exit is complete. This gives output delivery an explicit ordering point.
    func hideAndWait() async {
        if self.isHideInProgress {
            await withCheckedContinuation { continuation in
                self.hideWaiters.append(continuation)
            }
            return
        }

        self.isHideInProgress = true
        self.generation &+= 1
        let currentGeneration = self.generation
        await self.performHideAndWait(generation: currentGeneration)
        self.completeHideOperation()
    }

    private func performHideAndWait(generation currentGeneration: UInt64) async {
        let startedAt = ProcessInfo.processInfo.systemUptime
        Self.overlayBench("hide_called bottomVisible=\(self.isBottomOverlayVisible)")
        guard self.generation == currentGeneration else {
            Self.overlayBench("hide_return reason=stale_generation")
            return
        }

        // Stop monitoring active app changes
        ActiveAppMonitor.shared.stopMonitoring()

        // Hide bottom overlay if visible
        if self.isBottomOverlayVisible {
            await BottomOverlayWindowController.shared.hideAndWait()
            guard self.generation == currentGeneration else {
                Self.overlayBench("hide_return reason=stale_generation")
                return
            }
            self.isBottomOverlayVisible = false
        }

        // Cancel any pending retry operations
        self.pendingRetryTask?.cancel()
        self.pendingRetryTask = nil

        // Safety: reset processing state when hiding
        NotchContentState.shared.setProcessing(false)

        Self.overlayBench("hide_complete elapsedMs=\(Self.elapsedMs(since: startedAt))")
    }

    private func completeHideOperation() {
        self.isHideInProgress = false
        let waiters = self.hideWaiters
        self.hideWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resume() }
    }

    func setMode(_ mode: OverlayMode) {
        Self.overlayBench("set_mode mode=\(mode.rawValue)")

        // Always update NotchContentState to ensure UI stays in sync
        // (can get out of sync during show/hide transitions)
        let normalized = self.normalizedOverlayMode(mode)
        self.currentMode = normalized
        NotchContentState.shared.mode = normalized
    }

    func updateTranscriptionText(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedText.isEmpty || Self.transientOverlayStatusTexts.contains(trimmedText) {
            Self.overlayBench("text_update status=\(trimmedText.isEmpty ? "empty" : trimmedText)")
        }

        guard self.shouldShowOrTrackLivePreviewText else {
            if trimmedText.isEmpty || Self.transientOverlayStatusTexts.contains(trimmedText) {
                NotchContentState.shared.updateTranscription(text)
            } else if !NotchContentState.shared.transcriptionText.isEmpty {
                NotchContentState.shared.updateTranscription("")
            }
            return
        }
        NotchContentState.shared.updateTranscription(text)
    }

    func setProcessing(_ processing: Bool) {
        Self.overlayBench("set_processing processing=\(processing) bottomVisible=\(self.isBottomOverlayVisible)")
        NotchContentState.shared.setProcessing(processing)

        // If bottom overlay is visible, update its processing state
        if self.isBottomOverlayVisible {
            BottomOverlayWindowController.shared.setProcessing(processing)
            Self.overlayBench("set_processing_forwarded target=bottom")
            return
        }

        if processing {
            // If the overlay isn't visible, re-show it for the processing state
            if !self.isBottomOverlayVisible {
                Self.overlayBench("set_processing_reshow")
                // Use stored publisher or create empty one
                let publisher = self.lastAudioPublisher ?? Empty<CGFloat, Never>().eraseToAnyPublisher()
                self.show(audioLevelPublisher: publisher, mode: self.currentMode)
            }
        }
    }

    private static func overlayBench(_ message: String) {
        DebugLogger.shared.benchmark("OVERLAY_BENCH", message: "notch \(message)", source: "OverlayBenchmark")
    }

    private static func elapsedMs(since start: TimeInterval) -> Int {
        Int(((ProcessInfo.processInfo.systemUptime - start) * 1000).rounded())
    }

    private func normalizedOverlayMode(_ mode: OverlayMode) -> OverlayMode {
        mode
    }

    var shouldShowOrTrackLivePreviewText: Bool {
        return SettingsStore.shared.enableStreamingPreview
    }

}
