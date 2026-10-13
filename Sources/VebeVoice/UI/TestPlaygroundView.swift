import AppKit
import AVFoundation
import SwiftUI

/// In-app dictation workspace, with an editable result and a bounded live preview.
struct TestPlaygroundView: View {
    @EnvironmentObject var appServices: AppServices
    private var asr: ASRService { self.appServices.asr }
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme
    @State private var copied = false

    @Binding var playgroundUsed: Bool
    var isTranscriptionFocused: FocusState<Bool>.Binding
    let stopAndProcessTranscription: () async -> Void
    let startRecording: () -> Void

    private var busy: Bool { self.asr.isRunning || self.asr.isFinalizing }

    var body: some View {
        VibePageScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("A little space to think aloud")
                            .font(.system(size: 25, weight: .semibold))
                        Text("Speak naturally, then edit or copy your words here.")
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.theme.palette.secondaryText)
                    }
                    Spacer()
                    Image(systemName: "text.bubble.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(self.theme.palette.accent)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 8)

                DictationSessionStatus(asr: self.asr)

                HStack(spacing: 12) {
                    Label(self.asr.activeProviderName, systemImage: "cpu")
                        .lineLimit(1)
                    Spacer()
                    Text(self.settings.primaryDictationShortcutDisplayString)
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(self.theme.palette.cardBackground, in: RoundedRectangle(cornerRadius: 6))
                        .help("Your dictation shortcut")
                }
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)

                ThemedCard(hoverEffect: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text(self.asr.isRunning ? "Live preview" : "Your transcript")
                                .font(self.theme.typography.sectionTitle)
                            Spacer()
                            if !self.busy && !self.asr.finalText.isEmpty {
                                Text("\(self.asr.finalText.split(whereSeparator: { $0.isWhitespace }).count) words")
                                    .font(self.theme.typography.caption)
                                    .foregroundStyle(self.theme.palette.secondaryText)
                            }
                        }

                        if self.asr.isRunning {
                            ScrollView {
                                Text(self.asr.partialTranscription.isEmpty ? "Your words will appear here as you speak…" : self.asr.partialTranscription)
                                    .font(self.theme.typography.body)
                                    .foregroundStyle(self.asr.partialTranscription.isEmpty ? self.theme.palette.secondaryText : self.theme.palette.primaryText)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                    .textSelection(.enabled)
                            }
                            .frame(minHeight: 220, maxHeight: 300)
                            Text(self.settings.enableStreamingPreview
                                 ? "Preview shows recent speech. The final transcript includes the full recording."
                                 : "Live preview is off. Your full transcript will appear after you stop.")
                                .font(self.theme.typography.caption)
                                .foregroundStyle(self.theme.palette.secondaryText)
                        } else {
                            TextEditor(text: Binding(get: { self.asr.finalText }, set: { self.asr.finalText = $0 }))
                                .font(self.theme.typography.body)
                                .focused(self.isTranscriptionFocused)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 220)
                                .disabled(self.asr.isFinalizing)
                                .overlay(alignment: .topLeading) {
                                    if self.asr.finalText.isEmpty {
                                        Text(self.asr.isFinalizing ? "Turning your recording into text…" : "Start a recording, or type a note here.")
                                            .font(self.theme.typography.body)
                                            .foregroundStyle(self.theme.palette.secondaryText)
                                            .padding(.horizontal, 5)
                                            .padding(.top, 1)
                                            .allowsHitTesting(false)
                                    }
                                }
                                .accessibilityLabel("Editable transcript")
                        }

                        Divider()
                        HStack(spacing: 10) {
                            Button {
                                if self.asr.isRunning {
                                    Task { await self.stopAndProcessTranscription() }
                                } else {
                                    self.startRecording()
                                }
                            } label: {
                                Label(self.asr.isFinalizing ? "Processing…" : self.asr.isRunning ? "Stop & transcribe" : "Start recording",
                                      systemImage: self.asr.isRunning ? "stop.fill" : "mic.fill")
                            }
                            .vibeButton(.primary, size: .large, isRecording: self.asr.isRunning)
                            .disabled(self.asr.isFinalizing || (!self.asr.isRunning && (!(self.asr.isAsrReady || self.asr.modelsExistOnDisk) || self.asr.micStatus != .authorized)))
                            Spacer()
                            Button {
                                self.copied = ClipboardService.copyToClipboard(self.asr.finalText)
                            } label: {
                                Label(self.copied ? "Copied" : "Copy", systemImage: self.copied ? "checkmark" : "doc.on.doc")
                            }
                            .buttonStyle(.bordered)
                            .disabled(self.busy || self.asr.finalText.isEmpty)
                            Button("Clear") { self.asr.finalText = "" }
                                .buttonStyle(.bordered)
                                .disabled(self.busy || self.asr.finalText.isEmpty)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .onChange(of: self.asr.finalText) { _, text in
            self.copied = false
            if !text.isEmpty && !self.asr.isRunning {
                self.playgroundUsed = true
                self.settings.playgroundUsed = true
            }
        }
    }
}
