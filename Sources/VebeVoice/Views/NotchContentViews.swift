//
//  NotchContentViews.swift
//  VebeVoice
//
//  Created by Assistant
//

import AppKit
import Combine
import SwiftUI

// MARK: - Observable state for notch content (Singleton)

@MainActor
class NotchContentState: ObservableObject {
    static let shared = NotchContentState()
    /// Keep overlay state bounded even during very long recordings.
    private static let maxStoredTranscriptionCharacters = SettingsStore.transcriptionPreviewCharLimitRange.upperBound

    @Published var transcriptionText: String = ""
    @Published var mode: OverlayMode = .dictation
    /// Drives the overlay/waveform's processing visual state while the final
    /// transcription pass runs after the user stops recording.
    @Published var isProcessing: Bool = false

    /// Icon of the target app (where text will be typed)
    @Published var targetAppIcon: NSImage?

    /// The PID of the app we should restore focus to after interacting with overlays.
    /// Captured at recording start to keep the target stable for the session.
    @Published var recordingTargetPID: pid_t? = nil

    /// Cached transcription preview text to avoid recomputing on every render
    @Published private(set) var cachedPreviewText: String = ""

    private var cancellables = Set<AnyCancellable>()

    private init() {
        let previewLimitChanged = NotificationCenter.default.publisher(
            for: NSNotification.Name("TranscriptionPreviewCharLimitChanged")
        )
        let defaultsChanged = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)

        Publishers.Merge(previewLimitChanged, defaultsChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recomputeTranscriptionLines()
            }
            .store(in: &self.cancellables)
    }

    /// Set transcription processing state
    func setProcessing(_ processing: Bool) {
        self.isProcessing = processing
    }

    /// Update transcription and recompute cached lines
    func updateTranscription(_ text: String) {
        let boundedText = Self.tailCharacters(in: text, maxCharacters: Self.maxStoredTranscriptionCharacters)
        guard boundedText != self.transcriptionText else { return }

        self.transcriptionText = boundedText
        self.recomputeTranscriptionLines()
    }

    /// Recompute cached transcription lines (called only when text changes)
    private func recomputeTranscriptionLines() {
        let text = self.transcriptionText

        guard !text.isEmpty else {
            if !self.cachedPreviewText.isEmpty {
                self.cachedPreviewText = ""
            }
            return
        }

        let maxChars = SettingsStore.shared.transcriptionPreviewCharLimit
        let previewText = Self.tailCharacters(in: text, maxCharacters: maxChars)
        guard previewText != self.cachedPreviewText else { return }
        self.cachedPreviewText = previewText
    }

    private static func tailCharacters(in text: String, maxCharacters: Int) -> String {
        guard maxCharacters > 0, !text.isEmpty else { return "" }

        let start = text.index(text.endIndex, offsetBy: -maxCharacters, limitedBy: text.startIndex) ?? text.startIndex
        return String(text[start..<text.endIndex])
    }

    // MARK: - Bottom Overlay Audio Level

    @Published var bottomOverlayAudioLevel: CGFloat = 0 // Audio level for bottom overlay waveform
    @Published var isBottomOverlayReleaseTransitioning: Bool = false
    @Published var isBottomOverlayDismissing: Bool = false
    @Published var bottomOverlayDismissOffsetY: CGFloat = 8
    /// True while the bottom overlay panel is on-screen. Drives the waveform's
    /// display-linked animation so it can pause when the (reused) panel is hidden.
    @Published var isBottomOverlayPresented: Bool = false

    /// Called when the user requests copying the latest saved transcription entry.
    var onCopyLastRequested: (() -> Void)?
    /// Called when the user requests re-pasting the latest saved transcription entry.
    var onPasteLastRequested: (() -> Void)?
    /// Called when the user requests opening Preferences.
    var onOpenPreferencesRequested: (() -> Void)?
    /// Called when the user requests cancelling the current recording or overlay session.
    var onCancelRequested: (() -> Void)?

    func setBottomOverlayReleaseTransitioning(_ transitioning: Bool) {
        guard self.isBottomOverlayReleaseTransitioning != transitioning else { return }
        self.isBottomOverlayReleaseTransitioning = transitioning
    }

    func setBottomOverlayDismissing(_ dismissing: Bool) {
        guard self.isBottomOverlayDismissing != dismissing else { return }
        self.isBottomOverlayDismissing = dismissing
    }

    func setBottomOverlayPresented(_ presented: Bool) {
        guard self.isBottomOverlayPresented != presented else { return }
        self.isBottomOverlayPresented = presented
    }

    func setBottomOverlayDismissOffsetY(_ offset: CGFloat) {
        let normalizedOffset = max(offset, 8)
        guard abs(self.bottomOverlayDismissOffsetY - normalizedOffset) > 0.5 else { return }
        self.bottomOverlayDismissOffsetY = normalizedOffset
    }

}

// MARK: - Shared Mode Color Helper

extension OverlayMode {
    /// Mode-specific color for notch UI elements
    var notchColor: Color {
        switch self {
        case .dictation:
            return AppTheme.VibeBrand.ink.opacity(0.90)
        }
    }
}
