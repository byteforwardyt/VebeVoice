import AppKit
import Foundation

/// Bad-result reports are user-initiated emails, never background uploads: the report is
/// copied to the clipboard and a prefilled draft to support is opened in the user's mail app.
enum TranscriptionFeedbackReporter {
    struct Payload {
        let rawText: String
        let processedText: String
        let processingModel: String
        let comments: String
    }

    /// Mail clients truncate or reject very long `mailto:` URLs; the full report stays on the clipboard.
    private static let mailtoBodyLimit = 1500

    static func reportText(for payload: Payload) -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        var lines = [
            "VebeVoice transcription report",
            "App: \(version) (\(build)) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Model: \(payload.processingModel)",
            "",
            "Raw text:",
            payload.rawText,
            "",
            "Processed text:",
            payload.processedText,
        ]
        if !payload.comments.isEmpty {
            lines += ["", "Comment:", payload.comments]
        }
        return lines.joined(separator: "\n")
    }

    /// Returns false only if neither a mail draft nor the support page could be opened.
    @MainActor
    @discardableResult
    static func submit(_ payload: Payload) -> Bool {
        let report = self.reportText(for: payload)
        _ = ClipboardService.copyToClipboard(report)

        let body = report.count > self.mailtoBodyLimit
            ? String(report.prefix(self.mailtoBodyLimit)) + "\n\n[Truncated — the full report is on your clipboard.]"
            : report
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = VibeProductLinks.supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: "VebeVoice transcription report"),
            URLQueryItem(name: "body", value: body),
        ]
        if let url = components.url, NSWorkspace.shared.open(url) {
            return true
        }
        return NSWorkspace.shared.open(VibeProductLinks.support)
    }
}
