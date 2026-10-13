//
//  AppDelegate.swift
//  VebeVoice
//
//  Created by Barathwaj Anandan on 9/22/25.
//

import AppKit
import Carbon
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var didRevealMainWindowOnLaunch = false
    private var didRequestMainWindowReopen = false
    private var shouldSuppressNextReopenActivation = false
    private var wasLaunchedAsLoginItem = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bring up file logging + crash handlers immediately during launch.
        _ = FileLogger.shared
        // Must be read during the launch callback - the current Apple Event identifies
        // login-item launches (used to optionally start silently).
        self.wasLaunchedAsLoginItem = Self.detectLoginItemLaunch()
        DebugLogger.shared.info(
            "Application launched [loginItemLaunch=\(self.wasLaunchedAsLoginItem)]",
            source: "AppDelegate"
        )
        UNUserNotificationCenter.current().delegate = self

        // Initialize app settings (dock visibility, etc.)
        SettingsStore.shared.initializeAppSettings()
        LocalAPIServer.shared.start()

        let isTrueFirstOpen = SettingsStore.shared.recordFirstOpenIfNeeded()
        SettingsStore.shared.bootstrapOnboardingState(isTrueFirstOpen: isTrueFirstOpen)

        // Login Items can launch hidden; reveal the real SwiftUI window so ContentView startup runs.
        self.openMainWindowOnLaunch()

        // Note: App UI is designed with dark color scheme in mind
        // All gradients and effects are optimized for dark mode
    }

    func applicationWillTerminate(_ notification: Notification) {
        DebugLogger.shared.info("Application will terminate", source: "AppDelegate")
        self.shutdownASRRuntimeForTermination()
        LocalAPIServer.shared.stop()
        TranscriptionHistoryStore.waitForPendingSaves()
    }

    private func shutdownASRRuntimeForTermination() {
        var didFinishShutdown = false
        Task { @MainActor in
            await AppServices.shared.shutdownForTermination()
            didFinishShutdown = true
        }

        let deadline = Date().addingTimeInterval(8)
        while !didFinishShutdown, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        if !didFinishShutdown {
            DebugLogger.shared.warning(
                "Timed out waiting for ASR runtime shutdown during termination",
                source: "AppDelegate"
            )
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if self.shouldSuppressNextReopenActivation {
            self.shouldSuppressNextReopenActivation = false
            return true
        }

        // Ensure dock-icon reopen always foregrounds VebeVoice.
        sender.activate(ignoringOtherApps: true)

        return !self.bringMainWindowToFrontIfPresent()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    /// Whether this launch came from macOS Login Items. Reads the launch Apple Event,
    /// which is only valid during applicationDidFinishLaunching.
    /// VIBE_SIMULATE_LOGIN_LAUNCH=1 forces this on for testing, since real login-item
    /// launches can only be produced by logging in.
    private static func detectLoginItemLaunch() -> Bool {
        if ProcessInfo.processInfo.environment["VIBE_SIMULATE_LOGIN_LAUNCH"] == "1" {
            return true
        }
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == AEEventID(kAEOpenApplication)
            && event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }

    /// Apply the user's dock-visibility preference ("Hide from dock").
    /// Re-applied after operations that can reset the process activation policy - notably the
    /// LaunchServices reopen below, which restores the bundle default (.regular) even when the
    /// app is reopened without activation, so hide-from-dock is honored on login launches.
    private func applyDockVisibilityPolicy() {
        NSApp.setActivationPolicy(SettingsStore.shared.showInDock ? .regular : .accessory)
    }

    private func openMainWindowOnLaunch() {
        self.applyDockVisibilityPolicy()

        // Users can opt out of showing the window for login-item launches.
        // The window must still be CREATED either way - ContentView's appearance
        // bootstraps the menu bar and services - so the silent path realizes it
        // invisibly instead of skipping it.
        let revealWindow = !self.wasLaunchedAsLoginItem || SettingsStore.shared.showMainWindowAtLoginLaunch

        for delay in [0.1, 0.6, 1.2, 2.5, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                guard self.didRevealMainWindowOnLaunch == false else { return }

                if revealWindow {
                    NSApp.unhide(nil)
                    NSApp.activate(ignoringOtherApps: true)

                    if self.bringMainWindowToFrontIfPresent() {
                        self.didRevealMainWindowOnLaunch = true
                        return
                    }
                } else if self.bootMainWindowHiddenIfPresent() {
                    self.didRevealMainWindowOnLaunch = true
                    return
                }

                DebugLogger.shared.debug("Main window not ready during launch reveal retry", source: "AppDelegate")
                if delay >= 0.6 {
                    self.requestMainWindowReopenIfNeeded(activate: revealWindow)
                }
            }
        }
    }

    /// Realize the main window invisibly so ContentView's startup runs, then order it out.
    /// Used for login-item launches when "Show window when launched at login" is off.
    @discardableResult
    private func bootMainWindowHiddenIfPresent() -> Bool {
        guard let mainWindow = NSApp.windows.first(where: self.isMainWindow) else { return false }

        let originalAlpha = mainWindow.alphaValue
        mainWindow.alphaValue = 0
        mainWindow.orderFrontRegardless()

        // Give ContentView.onAppear time to finish its startup work (menu bar setup plus
        // the delayed service initialization), then put the window away. Alpha is restored
        // so opening it later from the menu bar shows it normally.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak mainWindow] in
            guard let mainWindow, mainWindow.alphaValue <= 0.01 else { return }
            mainWindow.orderOut(nil)
            mainWindow.alphaValue = originalAlpha
            DebugLogger.shared.info(
                "Main window booted hidden (show-at-login-launch disabled)",
                source: "AppDelegate"
            )
        }
        return true
    }

    private func requestMainWindowReopenIfNeeded(activate: Bool = true) {
        guard !self.didRequestMainWindowReopen else { return }
        self.didRequestMainWindowReopen = true

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        if !activate {
            self.shouldSuppressNextReopenActivation = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.shouldSuppressNextReopenActivation = false
            }
        }

        DebugLogger.shared.info("Requesting LaunchServices reopen to create SwiftUI main window", source: "AppDelegate")
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [weak self] _, error in
            if let error {
                DebugLogger.shared.error("LaunchServices reopen failed: \(error.localizedDescription)", source: "AppDelegate")
            }
            // The reopen restores the app's bundle default activation policy (.regular), which
            // would surface the Dock icon even when the user enabled "Hide from dock". Re-apply
            // the configured policy so login launches honor the setting. The completion
            // runs off the main thread, so hop back before touching NSApp.
            DispatchQueue.main.async {
                self?.applyDockVisibilityPolicy()
            }
        }
    }

    @discardableResult
    private func bringMainWindowToFrontIfPresent() -> Bool {
        if let mainWindow = NSApp.windows.first(where: self.isMainWindow) {
            if mainWindow.alphaValue <= 0.01 {
                mainWindow.alphaValue = 1
            }
            mainWindow.orderFrontRegardless()
            mainWindow.makeKeyAndOrderFront(nil)
            DebugLogger.shared.debug("Brought main window to front", source: "AppDelegate")
            return true
        }

        return false
    }

    private func isMainWindow(_ window: NSWindow) -> Bool {
        guard window.level == .normal else { return false }
        guard window.styleMask.contains(.titled) else { return false }
        return window.title == "VebeVoice" || window.title.contains("VebeVoice")
    }

    // MARK: - Manual Update Check

    @objc func checkForUpdatesManually() {
        // Users get builds from TheVibeFather only.
        DebugLogger.shared.info("Manual update → open TheVibeFather downloads", source: "AppDelegate")
        NSWorkspace.shared.open(VibeProductLinks.downloads)
        self.showUpdateAlert(
            title: "Updates",
            message: "VebeVoice updates are published on TheVibeFather.\n\nWe opened thevibefather.com — download the latest build there when a new version ships."
        )
    }

    @MainActor
    private func showUpdateAlert(title: String, message: String) {
        DebugLogger.shared.info("🔔 Showing alert: \(title)", source: "AppDelegate")
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
