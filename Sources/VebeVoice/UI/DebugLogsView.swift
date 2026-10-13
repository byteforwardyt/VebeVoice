import AppKit
import SwiftUI

/// Full Debug tab: live log stream + copy as text / Markdown / JSON.
struct DebugLogsView: View {
    @ObservedObject private var logger = DebugLogger.shared
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme

    @State private var filterText = ""
    @State private var levelFilter: DebugLogger.LogLevel? = nil
    @State private var autoScroll = true
    @State private var copyBanner: String?
    @State private var fileTail: String = ""

    private var filteredLogs: [DebugLogger.LogEntry] {
        self.logger.logs.filter { entry in
            if let levelFilter, entry.level != levelFilter { return false }
            if self.filterText.isEmpty { return true }
            let q = self.filterText.lowercased()
            return entry.message.lowercased().contains(q)
                || entry.source.lowercased().contains(q)
                || entry.level.rawValue.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VibePageLayout.sectionSpacing) {
            self.controlsCard
            self.logViewerCard
        }
        .vibePageContentColumn()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            self.loadFileTail()
            DebugLogger.shared.refreshLoggingEnabled()
        }
        .onChange(of: self.settings.enableDebugLogs) { _, _ in
            DebugLogger.shared.refreshLoggingEnabled()
        }
    }

    // MARK: - Controls

    private var controlsCard: some View {
        ThemedCard(hoverEffect: false) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Toggle(isOn: Binding(
                        get: { self.settings.enableDebugLogs },
                        set: { self.settings.enableDebugLogs = $0 }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Console logging")
                                .font(self.theme.typography.bodyStrong)
                            Text("File logs are always collected. This toggles Xcode/console spam.")
                                .font(self.theme.typography.caption)
                                .foregroundStyle(self.theme.palette.secondaryText)
                        }
                    }
                    .toggleStyle(.switch)

                    Spacer()

                    Button {
                        let url = FileLogger.shared.currentLogFileURL()
                        if FileManager.default.fileExists(atPath: url.path) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    } label: {
                        Label("Reveal Log File", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        self.loadFileTail()
                    } label: {
                        Label("Reload file", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(role: .destructive) {
                        self.logger.clear()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(self.theme.palette.tertiaryText)
                    TextField("Filter source or message…", text: self.$filterText)
                        .textFieldStyle(.plain)

                    Picker("Level", selection: Binding(
                        get: { self.levelFilter.map { $0.rawValue } ?? "ALL" },
                        set: { raw in
                            self.levelFilter = raw == "ALL" ? nil : DebugLogger.LogLevel(rawValue: raw)
                        }
                    )) {
                        Text("All").tag("ALL")
                        ForEach(DebugLogger.LogLevel.allCases, id: \.rawValue) { level in
                            Text(level.rawValue).tag(level.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)

                    Toggle("Auto-scroll", isOn: self.$autoScroll)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }

                HStack(spacing: 8) {
                    self.copyButton(title: "Copy", systemImage: "doc.on.doc", help: "Copy plain text") {
                        self.copyToPasteboard(self.exportPlainText())
                        self.flashCopy("Copied text")
                    }
                    self.copyButton(title: "Copy MD", systemImage: "text.alignleft", help: "Copy Markdown report") {
                        self.copyToPasteboard(self.exportMarkdown())
                        self.flashCopy("Copied Markdown")
                    }
                    self.copyButton(title: "Copy JSON", systemImage: "curlybraces", help: "Copy JSON array") {
                        self.copyToPasteboard(self.exportJSON())
                        self.flashCopy("Copied JSON")
                    }

                    Spacer()

                    Text("\(self.filteredLogs.count) / \(self.logger.logs.count) entries")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.tertiaryText)

                    if let copyBanner {
                        Text(copyBanner)
                            .font(self.theme.typography.captionStrong)
                            .foregroundStyle(self.theme.palette.accent)
                            .transition(.opacity)
                    }
                }
            }
            .padding(14)
        }
    }

    private func copyButton(title: String, systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.borderedProminent)
        .tint(self.theme.palette.accent)
        .controlSize(.small)
        .help(help)
        .disabled(self.logger.logs.isEmpty && self.fileTail.isEmpty)
    }

    // MARK: - Log viewer

    private var logViewerCard: some View {
        ThemedCard(hoverEffect: false) {
            VStack(alignment: .leading, spacing: 0) {
                if self.filteredLogs.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "ladybug")
                            .font(.system(size: 28))
                            .foregroundStyle(self.theme.palette.tertiaryText)
                        Text(self.logger.logs.isEmpty ? "No live logs yet" : "No matches")
                            .font(self.theme.typography.bodyStrong)
                            .foregroundStyle(self.theme.palette.secondaryText)
                        Text(
                            self.logger.logs.isEmpty
                                ? "Use the app — logs stream here as events fire. You can also reload the on-disk log file."
                                : "Try a different filter or level."
                        )
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.tertiaryText)
                        .multilineTextAlignment(.center)

                        if !self.fileTail.isEmpty {
                            Divider().padding(.vertical, 8)
                            Text("File tail (last lines on disk)")
                                .font(self.theme.typography.captionStrong)
                                .foregroundStyle(self.theme.palette.secondaryText)
                            ScrollView {
                                Text(self.fileTail)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(self.theme.palette.primaryText)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(minHeight: 180, maxHeight: 320)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(24)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(self.filteredLogs) { entry in
                                    self.logRow(entry)
                                        .id(entry.id)
                                }
                                Color.clear.frame(height: 1).id("log-bottom")
                            }
                            .padding(.vertical, 4)
                        }
                        .frame(minHeight: 360, maxHeight: .infinity)
                        .onChange(of: self.logger.logs.count) { _, _ in
                            guard self.autoScroll else { return }
                            DispatchQueue.main.async {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    proxy.scrollTo("log-bottom", anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func logRow(_ entry: DebugLogger.LogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.formattedTimestamp)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(self.theme.palette.tertiaryText)
                .frame(width: 78, alignment: .leading)

            Text(entry.level.rawValue)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(entry.level.color)
                .frame(width: 48, alignment: .leading)

            Text(entry.source)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(self.theme.palette.secondaryText)
                .frame(width: 110, alignment: .leading)
                .lineLimit(1)

            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(self.theme.palette.primaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            entry.level == .error
                ? Color.red.opacity(0.08)
                : (entry.level == .warning ? Color.orange.opacity(0.06) : Color.clear)
        )
    }

    // MARK: - Export

    private func exportPlainText() -> String {
        if !self.logger.logs.isEmpty {
            return self.logger.exportLogs()
        }
        return self.fileTail
    }

    private func exportMarkdown() -> String {
        if !self.logger.logs.isEmpty {
            return self.logger.exportLogsMarkdown()
        }
        return """
        # VebeVoice Debug Log (file tail)

        ```
        \(self.fileTail)
        ```
        """
    }

    private func exportJSON() -> String {
        if !self.logger.logs.isEmpty {
            return self.logger.exportLogsJSON()
        }
        // File tail as a single JSON string payload when live buffer is empty.
        let payload: [String: Any] = [
            "source": "file_tail",
            "path": FileLogger.shared.currentLogFileURL().path,
            "text": self.fileTail,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
           let string = String(data: data, encoding: .utf8)
        {
            return string
        }
        return "{}"
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func flashCopy(_ message: String) {
        withAnimation {
            self.copyBanner = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation {
                if self.copyBanner == message {
                    self.copyBanner = nil
                }
            }
        }
    }

    private func loadFileTail() {
        let url = FileLogger.shared.currentLogFileURL()
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            self.fileTail = ""
            return
        }
        defer { try? handle.close() }

        let maxBytes: UInt64 = 128 * 1024
        let size = (try? handle.seekToEnd()) ?? 0
        if size > maxBytes {
            try? handle.seek(toOffset: size - maxBytes)
        } else {
            try? handle.seek(toOffset: 0)
        }
        let data = handle.readDataToEndOfFile()
        var text = String(data: data, encoding: .utf8) ?? ""
        // If we mid-line seeked, drop the partial first line.
        if size > maxBytes, let nl = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: nl)...])
        }
        self.fileTail = text
    }
}
