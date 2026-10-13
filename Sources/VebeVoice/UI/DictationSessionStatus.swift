import AVFoundation
import SwiftUI

/// Shared recording status. The one-second timer exists only during capture.
struct DictationSessionStatus: View {
    @ObservedObject var asr: ASRService
    @Environment(\.theme) private var theme

    private var title: String {
        if self.asr.isFinalizing { return "Finishing your transcript" }
        if self.asr.isRunning { return "Listening to you" }
        if self.asr.micStatus != .authorized { return "Finish microphone setup" }
        return self.asr.modelsExistOnDisk || self.asr.isAsrReady ? "Ready when you are" : "Set up your voice engine"
    }

    private var subtitle: String {
        if self.asr.isFinalizing { return "Longer recordings can take a moment. Keep the app open." }
        if self.asr.isRunning { return "Keep talking. Stop when your thought is complete." }
        if self.asr.micStatus != .authorized { return "VebeVoice needs microphone access before it can listen." }
        return "The microphone is idle until you start recording."
    }

    var body: some View {
        ThemedCard(style: .standard, padding: 18) {
            self.content
        }
    }

    private var content: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(self.asr.isRunning ? Color.red.opacity(0.12) : self.theme.palette.accent.opacity(0.12))
                if self.asr.isFinalizing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: self.asr.isRunning ? "waveform" : "mic")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(self.asr.isRunning ? Color.red : self.theme.palette.accent)
                }
            }
            .frame(width: 48, height: 48)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(self.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(self.theme.palette.primaryText)
                Text(self.subtitle)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if self.asr.isRunning, let started = self.asr.recordingStartedAt {
                Text(started, style: .timer)
                    .font(.system(size: 22, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(self.theme.palette.primaryText)
                    .accessibilityLabel("Recording duration")
            } else if self.asr.isFinalizing {
                Text(String(format: "%d:%02d", Int(self.asr.lastRecordingDuration) / 60, Int(self.asr.lastRecordingDuration) % 60))
                    .font(.system(size: 22, weight: .medium, design: .monospaced))
                    .foregroundStyle(self.theme.palette.primaryText)
                    .accessibilityLabel("Recorded duration")
            }
        }
    }
}
