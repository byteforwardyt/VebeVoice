//
//  BottomOverlayView.swift
//  VebeVoice
//
//  Bottom overlay for transcription (alternative to notch overlay)
//

import AppKit
import Combine
import SwiftUI

// MARK: - Bottom Overlay Window Controller

@MainActor
final class BottomOverlayWindowController {
    static let shared = BottomOverlayWindowController()

    private var window: NSPanel?
    private var audioSubscription: AnyCancellable?
    private var pendingResizeWorkItem: DispatchWorkItem?
    private var pendingReleaseTransitionResetWorkItem: DispatchWorkItem?
    private var localMouseDownMonitor: Any?
    private var globalMouseDownMonitor: Any?
    private var targetScreen: NSScreen?
    private var releaseTransitionActiveUntil: Date?
    private var deferredResizePending = false
    private var presentationGeneration: UInt64 = 0
    private let presentationDuration: TimeInterval = 0.05
    private let dismissalDuration: TimeInterval = 0.02
    private var isHideInProgress = false
    private var hideWaiters: [CheckedContinuation<Void, Never>] = []

    private init() {
        NotificationCenter.default.addObserver(forName: NSNotification.Name("OverlayOffsetChanged"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.positionWindow()
            }
        }
        NotificationCenter.default.addObserver(forName: NSNotification.Name("OverlaySizeChanged"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleSizeAndPositionUpdate(after: 0)
            }
        }
    }

    func show(audioPublisher: AnyPublisher<CGFloat, Never>, mode: OverlayMode) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        Self.overlayBench("bottom_show_start mode=\(mode.rawValue) windowExists=\(self.window != nil)")
        self.presentationGeneration &+= 1
        let currentGeneration = self.presentationGeneration

        self.endReleaseTransition(flushDeferredUpdate: false)
        self.pendingResizeWorkItem?.cancel()
        self.pendingResizeWorkItem = nil
        BottomOverlayActionsMenuController.shared.hide()
        self.ensureMouseDownMonitors()

        // Update mode in content state
        NotchContentState.shared.mode = mode
        NotchContentState.shared.updateTranscription("")
        NotchContentState.shared.bottomOverlayAudioLevel = 0
        NotchContentState.shared.setBottomOverlayDismissOffsetY(8)
        NotchContentState.shared.setBottomOverlayDismissing(false)

        // Subscribe to audio levels and route through NotchContentState
        self.audioSubscription?.cancel()
        self.audioSubscription = audioPublisher
            .receive(on: DispatchQueue.main)
            .sink { level in
                NotchContentState.shared.bottomOverlayAudioLevel = level
            }

        // Create window if needed
        if self.window == nil {
            self.createWindow()
        }

        self.targetScreen = OverlayScreenResolver.screenForCurrentPointer()
        self.positionWindow()

        // Order the panel immediately, then use a very short fade so the first
        // response is instant without the overlay visually popping into place.
        self.window?.alphaValue = 0
        self.window?.orderFrontRegardless()
        NotchContentState.shared.setBottomOverlayPresented(true)
        Self.overlayBench("bottom_order_front elapsedMs=\(Self.elapsedMs(since: startedAt))")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = self.presentationDuration
            context.allowsImplicitAnimation = true
            self.window?.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + self.presentationDuration) { [weak self] in
            guard let self, self.presentationGeneration == currentGeneration else { return }
            Self.overlayBench("bottom_fade_complete elapsedMs=\(Self.elapsedMs(since: startedAt))")
        }
    }

    /// Performs the brief exit animation and returns after the panel is fully
    /// ordered out, allowing callers to deliver text only after it disappears.
    func hideAndWait() async {
        if self.isHideInProgress {
            await withCheckedContinuation { continuation in
                self.hideWaiters.append(continuation)
            }
            return
        }

        self.isHideInProgress = true
        self.presentationGeneration &+= 1
        let currentGeneration = self.presentationGeneration
        await self.performHideAndWait(generation: currentGeneration)
        self.completeHideOperation()
    }

    private func completeHideOperation() {
        self.isHideInProgress = false
        let waiters = self.hideWaiters
        self.hideWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resume() }
    }

    private func performHideAndWait(generation currentGeneration: UInt64) async {
        let startedAt = ProcessInfo.processInfo.systemUptime
        Self.overlayBench("bottom_hide_start windowExists=\(self.window != nil)")
        guard self.presentationGeneration == currentGeneration else {
            Self.overlayBench("bottom_hide_return reason=stale_generation")
            return
        }

        guard let window = self.window, window.isVisible else {
            self.clearPresentationResources()
            self.endReleaseTransition(flushDeferredUpdate: false)
            NotchContentState.shared.setBottomOverlayDismissing(false)
            NotchContentState.shared.setBottomOverlayPresented(false)
            NotchContentState.shared.targetAppIcon = nil
            Self.overlayBench("bottom_hide_return reason=no_window")
            return
        }

        NotchContentState.shared.setBottomOverlayReleaseTransitioning(true)
        NotchContentState.shared.setBottomOverlayDismissOffsetY(8)
        NotchContentState.shared.setBottomOverlayDismissing(true)

        // Start the visual response first. Resource cleanup then happens inside
        // this same short budget instead of delaying the beginning of the fade.
        let animationStartedAt = ProcessInfo.processInfo.systemUptime
        Self.overlayBench("bottom_hide_animation_start")
        await NSAnimationContext.runAnimationGroup { context in
            context.duration = self.dismissalDuration
            context.allowsImplicitAnimation = true
            window.animator().alphaValue = 0
        }
        await Task.yield()
        guard self.presentationGeneration == currentGeneration else {
            Self.overlayBench("bottom_hide_return reason=stale_generation")
            return
        }
        self.clearPresentationResources()

        let elapsed = ProcessInfo.processInfo.systemUptime - animationStartedAt
        let remainingDuration = max(0, self.dismissalDuration - elapsed)
        if remainingDuration > 0 {
            try? await Task.sleep(nanoseconds: UInt64(remainingDuration * 1_000_000_000))
        }

        guard self.presentationGeneration == currentGeneration else {
            Self.overlayBench("bottom_hide_return reason=stale_generation")
            return
        }

        window.orderOut(nil)
        window.alphaValue = 1
        self.endReleaseTransition(flushDeferredUpdate: false)
        NotchContentState.shared.setBottomOverlayDismissing(false)
        NotchContentState.shared.setBottomOverlayPresented(false)
        NotchContentState.shared.targetAppIcon = nil
        Self.overlayBench("bottom_hide_complete elapsedMs=\(Self.elapsedMs(since: startedAt))")
    }

    private func clearPresentationResources() {
        self.audioSubscription?.cancel()
        self.audioSubscription = nil
        self.pendingResizeWorkItem?.cancel()
        self.pendingResizeWorkItem = nil
        self.pendingReleaseTransitionResetWorkItem?.cancel()
        self.targetScreen = nil
        self.removeMouseDownMonitors()
        BottomOverlayActionsMenuController.shared.hide()
        NotchContentState.shared.setProcessing(false)
        NotchContentState.shared.bottomOverlayAudioLevel = 0
    }

    func setProcessing(_ processing: Bool) {
        Self.overlayBench("bottom_set_processing processing=\(processing)")
        NotchContentState.shared.setProcessing(processing)
    }

    func refreshSizeForContent() {
        self.scheduleSizeAndPositionUpdate()
    }

    func beginReleaseTransition(duration: TimeInterval = 0.28) {
        let now = Date()
        let deadline = now.addingTimeInterval(max(duration, 0.12))
        if let existingDeadline = self.releaseTransitionActiveUntil, existingDeadline > deadline {
            self.releaseTransitionActiveUntil = existingDeadline
        } else {
            self.releaseTransitionActiveUntil = deadline
        }

        self.pendingReleaseTransitionResetWorkItem?.cancel()

        guard let activeDeadline = self.releaseTransitionActiveUntil else { return }
        let resetWorkItem = DispatchWorkItem { [weak self] in
            self?.endReleaseTransition()
        }
        self.pendingReleaseTransitionResetWorkItem = resetWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + max(activeDeadline.timeIntervalSince(now), 0), execute: resetWorkItem)

        self.audioSubscription?.cancel()
        self.audioSubscription = nil
        NotchContentState.shared.bottomOverlayAudioLevel = 0
        NotchContentState.shared.setBottomOverlayReleaseTransitioning(true)
    }

    func endReleaseTransition(flushDeferredUpdate: Bool = true) {
        self.pendingReleaseTransitionResetWorkItem?.cancel()
        self.pendingReleaseTransitionResetWorkItem = nil
        self.releaseTransitionActiveUntil = nil
        NotchContentState.shared.setBottomOverlayReleaseTransitioning(false)

        let shouldFlush = flushDeferredUpdate && self.deferredResizePending
        self.deferredResizePending = false

        if shouldFlush, self.window?.isVisible == true {
            self.scheduleSizeAndPositionUpdate(after: 0)
        }
    }

    private static func overlayBench(_ message: String) {
        DebugLogger.shared.benchmark("OVERLAY_BENCH", message: message, source: "OverlayBenchmark")
    }

    private static func elapsedMs(since start: TimeInterval) -> Int {
        Int(((ProcessInfo.processInfo.systemUptime - start) * 1000).rounded())
    }

    private func scheduleSizeAndPositionUpdate(after delay: TimeInterval = 0.08) {
        if self.isReleaseTransitionActive {
            self.deferredResizePending = true
            return
        }

        self.pendingResizeWorkItem?.cancel()

        // Debounce rapid streaming updates to avoid resize thrash.
        let resizeWorkItem = DispatchWorkItem { [weak self] in
            self?.updateSizeAndPosition()
        }
        self.pendingResizeWorkItem = resizeWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: resizeWorkItem)
    }

    /// Update window size based on current SwiftUI content and re-position
    private func updateSizeAndPosition() {
        if self.isReleaseTransitionActive {
            self.deferredResizePending = true
            return
        }

        guard let window = window, let hostingView = window.contentView as? NSHostingView<BottomOverlayView> else { return }

        // Re-calculate fitting size for the new layout constants (pixel-snapped)
        let newSize = Self.snappedContentSize(hostingView.fittingSize)

        // Avoid redundant content-size updates while AppKit is already resolving constraints.
        // Re-applying the same size can trigger unnecessary update-constraints churn.
        let currentSize = window.contentView?.frame.size ?? window.frame.size
        let widthChanged = abs(currentSize.width - newSize.width) > 0.5
        let heightChanged = abs(currentSize.height - newSize.height) > 0.5

        if widthChanged || heightChanged {
            // Resize from the current origin to avoid AppKit's default top-left anchoring,
            // which can visually push the overlay down before we re-position it.
            let currentOrigin = window.frame.origin
            let resizedFrame = NSRect(origin: currentOrigin, size: newSize)
            window.setFrame(resizedFrame, display: false)
        }

        // Re-position
        self.positionWindow()
    }

    private func createWindow() {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // SwiftUI handles shadow
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let contentView = BottomOverlayView()
        let hostingView = BottomOverlayHostingView(rootView: contentView)

        // Let SwiftUI determine the size, then snap to whole points so the
        // content lays out on the pixel grid (fittingSize is often fractional,
        // which softens text/bars on Retina).
        let fittingSize = Self.snappedContentSize(hostingView.fittingSize)
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)

        // Make hosting view fully transparent and force integer pixel sampling.
        // Soft / blurred edges when text appears are usually sub-pixel rasterization
        // of a clear NSHostingView layer as the window resizes with streaming text.
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        hostingView.layer?.isOpaque = false
        hostingView.layer?.allowsEdgeAntialiasing = false
        hostingView.layer?.magnificationFilter = .nearest
        hostingView.layer?.minificationFilter = .nearest

        panel.setContentSize(fittingSize)
        panel.contentView = hostingView

        self.window = panel
    }

    /// Round a SwiftUI fitting size up to whole points so sublayers land on the
    /// pixel grid. Fractional content sizes are the main cause of soft,
    /// non-Retina-crisp overlay rendering.
    private static func snappedContentSize(_ size: NSSize) -> NSSize {
        NSSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
    }

    private var isReleaseTransitionActive: Bool {
        guard let deadline = self.releaseTransitionActiveUntil else { return false }
        if deadline > Date() {
            return true
        }

        self.releaseTransitionActiveUntil = nil
        return false
    }

    private func ensureMouseDownMonitors() {
        if self.localMouseDownMonitor == nil {
            self.localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                let clickPoint: NSPoint
                if let window = event.window {
                    clickPoint = window.convertPoint(toScreen: event.locationInWindow)
                } else {
                    clickPoint = NSEvent.mouseLocation
                }

                Task { @MainActor [weak self] in
                    self?.dismissMenusForClick(screenPoint: clickPoint)
                }
                return event
            }
        }

        if self.globalMouseDownMonitor == nil {
            self.globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                let clickPoint = NSEvent.mouseLocation
                Task { @MainActor [weak self] in
                    self?.dismissMenusForClick(screenPoint: clickPoint)
                }
            }
        }
    }

    private func removeMouseDownMonitors() {
        if let monitor = self.localMouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            self.localMouseDownMonitor = nil
        }
        if let monitor = self.globalMouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            self.globalMouseDownMonitor = nil
        }
    }

    @MainActor
    private func dismissMenusForClick(screenPoint: NSPoint) {
        guard self.window?.isVisible == true else { return }
        BottomOverlayActionsMenuController.shared.dismissIfNeeded(for: screenPoint)
    }

    private func positionWindow() {
        // Safe check for window and screen availability
        guard let window = window else { return }

        let screen = self.targetScreen ?? window.screen ?? OverlayScreenResolver.screenForCurrentPointer()
        guard let screen = screen else { return }

        let fullFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let windowSize = window.frame.size

        // Horizontal centering
        let x = fullFrame.midX - windowSize.width / 2

        // Vertical positioning with safety clamping
        let offset = SettingsStore.shared.overlayBottomOffset

        // Calculate raw position
        var y = visibleFrame.minY + CGFloat(offset)

        // Safety Clamping:
        // 1. Min: Ensure it's at least visibleFrame.minY (not below the dock/visible area)
        // 2. Max: Ensure it doesn't cross the top of the visible frame minus its own height
        let minY = visibleFrame.minY + 10 // Small buffer from absolute bottom
        let maxY = visibleFrame.maxY - windowSize.height - 40 // Buffer from top

        y = max(min(y, maxY), minY)

        // Snap the origin to the screen's backing pixel grid. A sub-pixel origin
        // makes AppKit sample the whole overlay between physical pixels, which
        // reads as soft / non-Retina on 2x displays.
        let scale = screen.backingScaleFactor
        let snappedX = (x * scale).rounded() / scale
        let snappedY = (y * scale).rounded() / scale

        // Apply position directly to avoid implicit frame animations during hover-driven resizes.
        window.setFrameOrigin(NSPoint(x: snappedX, y: snappedY))

        // Keep the hosting layer rendering at the display's scale (belt-and-suspenders
        // in case the panel was created before it adopted the target screen).
        if let hostingView = window.contentView {
            hostingView.layer?.contentsScale = scale
            hostingView.layer?.allowsEdgeAntialiasing = false
        }
    }
}

@MainActor
final class BottomOverlayActionsMenuController {
    static let shared = BottomOverlayActionsMenuController()

    private var menuWindow: NSPanel?
    private var hostingView: NSHostingView<BottomOverlayActionsMenuView>?
    private var selectorFrameInScreen: CGRect = .zero
    private weak var parentWindow: NSWindow?
    private var menuMaxWidth: CGFloat = 220
    private var menuGap: CGFloat = 6

    private var isHoveringSelector = false
    private var isHoveringMenu = false
    private var pendingShowWorkItem: DispatchWorkItem?
    private var pendingHideWorkItem: DispatchWorkItem?
    private var pendingPositionWorkItem: DispatchWorkItem?

    private init() {}

    func updateAnchor(selectorFrameInScreen: CGRect, parentWindow: NSWindow?, maxWidth: CGFloat, menuGap: CGFloat) {
        guard selectorFrameInScreen.width > 0, selectorFrameInScreen.height > 0 else { return }

        let resolvedMaxWidth = max(maxWidth, 120)
        let widthChanged = abs(self.menuMaxWidth - resolvedMaxWidth) > 0.5

        self.selectorFrameInScreen = selectorFrameInScreen
        self.parentWindow = parentWindow
        self.menuMaxWidth = resolvedMaxWidth
        self.menuGap = max(menuGap, 0)

        if self.menuWindow?.isVisible == true {
            if widthChanged {
                self.updateMenuContent()
            }
            self.attachToParentWindowIfNeeded()
            self.scheduleMenuPositionUpdate()
        }
    }

    func selectorHoverChanged(_ hovering: Bool) {
        // Hover-open disabled: menu is click/tap driven.
    }

    func menuHoverChanged(_ hovering: Bool) {
        // Hover-open disabled: menu is click/tap driven.
    }

    func toggleFromTap() {
        if self.menuWindow?.isVisible == true {
            self.hide()
            return
        }
        self.showMenuIfPossible()
    }

    func hide() {
        self.pendingShowWorkItem?.cancel()
        self.pendingShowWorkItem = nil
        self.pendingHideWorkItem?.cancel()
        self.pendingHideWorkItem = nil
        self.pendingPositionWorkItem?.cancel()
        self.pendingPositionWorkItem = nil

        self.isHoveringSelector = false
        self.isHoveringMenu = false

        if let menuWindow = self.menuWindow, let parent = menuWindow.parent {
            parent.removeChildWindow(menuWindow)
        }
        self.menuWindow?.orderOut(nil)
    }

    func dismissIfNeeded(for screenPoint: NSPoint) {
        guard self.menuWindow?.isVisible == true else { return }
        let insideMenu = self.menuWindow?.frame.contains(screenPoint) ?? false
        let insideSelector = self.selectorFrameInScreen.contains(screenPoint)
        if !insideMenu, !insideSelector {
            self.hide()
        }
    }

    private func scheduleMenuPositionUpdate() {
        guard self.pendingPositionWorkItem == nil else { return }

        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPositionWorkItem = nil
            self.updateMenuSizeAndPosition()
        }

        self.pendingPositionWorkItem = task
        DispatchQueue.main.async(execute: task)
    }

    private func showMenuIfPossible() {
        guard self.selectorFrameInScreen.width > 0, self.selectorFrameInScreen.height > 0 else { return }

        self.createWindowIfNeeded()
        self.updateMenuContent()
        self.attachToParentWindowIfNeeded()
        self.updateMenuSizeAndPosition()
        self.menuWindow?.orderFrontRegardless()
    }

    private func createWindowIfNeeded() {
        guard self.menuWindow == nil else { return }

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let contentView = BottomOverlayActionsMenuView(
            maxWidth: self.menuMaxWidth,
            onHoverChanged: { [weak self] hovering in
                self?.menuHoverChanged(hovering)
            },
            onDismissRequested: { [weak self] in
                self?.hide()
            }
        )

        let hostingView = NSHostingView(rootView: contentView)
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        panel.setContentSize(fittingSize)
        panel.contentView = hostingView

        self.hostingView = hostingView
        self.menuWindow = panel
    }

    private func updateMenuContent() {
        let rootView = BottomOverlayActionsMenuView(
            maxWidth: self.menuMaxWidth,
            onHoverChanged: { [weak self] hovering in
                self?.menuHoverChanged(hovering)
            },
            onDismissRequested: { [weak self] in
                self?.hide()
            }
        )
        self.hostingView?.rootView = rootView
    }

    private func attachToParentWindowIfNeeded() {
        guard let menuWindow = self.menuWindow else { return }

        if let currentParent = menuWindow.parent, currentParent !== self.parentWindow {
            currentParent.removeChildWindow(menuWindow)
        }

        if let parentWindow = self.parentWindow, menuWindow.parent !== parentWindow {
            parentWindow.addChildWindow(menuWindow, ordered: .above)
        }
    }

    private func updateMenuSizeAndPosition() {
        guard let menuWindow = self.menuWindow, let hostingView = self.hostingView else { return }
        guard self.selectorFrameInScreen.width > 0, self.selectorFrameInScreen.height > 0 else { return }

        let fittingSize = hostingView.fittingSize
        guard fittingSize.width > 0, fittingSize.height > 0 else { return }

        let preferredX = self.selectorFrameInScreen.midX - (fittingSize.width / 2)
        let preferredY = self.selectorFrameInScreen.maxY + self.menuGap

        let screen = self.parentWindow?.screen
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: self.selectorFrameInScreen.midX, y: self.selectorFrameInScreen.midY)) })
            ?? NSScreen.main

        var targetX = preferredX
        var targetY = preferredY

        if let screen {
            let visible = screen.visibleFrame
            let horizontalInset: CGFloat = 8
            let verticalInset: CGFloat = 8

            if fittingSize.width < visible.width - (horizontalInset * 2) {
                targetX = max(visible.minX + horizontalInset, min(preferredX, visible.maxX - fittingSize.width - horizontalInset))
            } else {
                targetX = visible.minX + horizontalInset
            }

            if fittingSize.height < visible.height - (verticalInset * 2) {
                targetY = max(visible.minY + verticalInset, min(preferredY, visible.maxY - fittingSize.height - verticalInset))
            } else {
                targetY = visible.minY + verticalInset
            }
        }

        let targetFrame = NSRect(x: targetX, y: targetY, width: fittingSize.width, height: fittingSize.height)
        let currentFrame = menuWindow.frame
        let frameTolerance: CGFloat = 0.5
        let isSameFrame =
            abs(currentFrame.origin.x - targetFrame.origin.x) <= frameTolerance &&
            abs(currentFrame.origin.y - targetFrame.origin.y) <= frameTolerance &&
            abs(currentFrame.size.width - targetFrame.size.width) <= frameTolerance &&
            abs(currentFrame.size.height - targetFrame.size.height) <= frameTolerance

        if !isSameFrame {
            menuWindow.setFrame(targetFrame, display: false)
        }
    }
}

private struct BottomOverlayActionsMenuView: View {
    @ObservedObject private var contentState = NotchContentState.shared
    @ObservedObject private var historyStore = TranscriptionHistoryStore.shared

    let maxWidth: CGFloat
    let onHoverChanged: (Bool) -> Void
    let onDismissRequested: () -> Void

    @State private var hoveredRowID: String?

    private var latestEntry: TranscriptionHistoryEntry? {
        self.historyStore.entries.first
    }

    private var canCopyLast: Bool {
        guard !self.contentState.isProcessing else { return false }
        return self.latestEntry?.clipboardText != nil
    }

    private var canPasteLast: Bool {
        self.canCopyLast
    }

    private func rowBackground(isSelected: Bool, rowID: String) -> some View {
        let isHovered = self.hoveredRowID == rowID
        let fillColor: Color
        if isSelected {
            fillColor = Color.white.opacity(0.28)
        } else if isHovered {
            fillColor = Color.white.opacity(0.20)
        } else {
            fillColor = Color.clear
        }

        let strokeColor: Color
        if isSelected {
            strokeColor = Color.white.opacity(0.38)
        } else if isHovered {
            strokeColor = Color.white.opacity(0.24)
        } else {
            strokeColor = Color.clear
        }

        return RoundedRectangle(cornerRadius: 7)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(strokeColor, lineWidth: 1)
            )
    }

    private func actionRow(
        title: String,
        icon: String,
        rowID: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: {
            guard enabled else { return }
            action()
            self.onDismissRequested()
        }) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(self.rowBackground(isSelected: false, rowID: rowID))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering in
            guard enabled else {
                self.hoveredRowID = nil
                return
            }
            self.hoveredRowID = hovering ? rowID : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.actionRow(
                title: "Copy Last Transcription",
                icon: "doc.on.doc",
                rowID: "copy_last",
                enabled: self.canCopyLast
            ) {
                self.contentState.onCopyLastRequested?()
            }

            self.actionRow(
                title: "Paste Last Transcription",
                icon: "arrow.down.doc",
                rowID: "paste_last",
                enabled: self.canPasteLast
            ) {
                self.contentState.onPasteLastRequested?()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(VibeOverlayMenuSurface())
        .cornerRadius(8)
        .frame(maxWidth: self.maxWidth)
        .preferredColorScheme(SettingsStore.shared.themePreference.preferredColorScheme)
        .onHover { hovering in
            self.onHoverChanged(hovering)
        }
    }
}

private enum PillShadowMetrics {
    // Keep in sync with the pill shadow in VibeOverlayGlassChrome.
    static let radius: CGFloat = 4
    static let yOffset: CGFloat = 2
    /// Hit-test inset must cover the visible shadow extent (radius + |offset|)
    /// plus the outer padding margin so the shadow region doesn't intercept clicks.
    static let hitTestInset: CGFloat = radius + abs(yOffset) + 12
}

private struct PromptSelectorAnchorReader: NSViewRepresentable {
    let onFrameChange: (CGRect, NSWindow?) -> Void

    func makeNSView(context: Context) -> AnchorReportingView {
        let view = AnchorReportingView()
        view.onFrameChange = self.onFrameChange
        return view
    }

    func updateNSView(_ nsView: AnchorReportingView, context: Context) {
        nsView.onFrameChange = self.onFrameChange
        nsView.reportFrame(force: true)
    }

    final class AnchorReportingView: NSView {
        var onFrameChange: ((CGRect, NSWindow?) -> Void)?
        private var windowObservers: [NSObjectProtocol] = []
        private var lastReportedFrameInScreen: CGRect = .null
        private weak var lastReportedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            self.installWindowObservers()
            self.reportFrame(force: true)
        }

        override func layout() {
            super.layout()
            self.reportFrame()
        }

        deinit {
            self.cleanup()
        }

        func cleanup() {
            for observer in self.windowObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            self.windowObservers.removeAll()
        }

        private func installWindowObservers() {
            self.cleanup()
            guard let window = self.window else { return }

            let center = NotificationCenter.default
            self.windowObservers.append(
                center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                    self?.reportFrame()
                }
            )
            self.windowObservers.append(
                center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                    self?.reportFrame()
                }
            )
            self.windowObservers.append(
                center.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in
                    self?.reportFrame()
                }
            )
        }

        func reportFrame(force: Bool = false) {
            guard let window = self.window else {
                if force || !self.lastReportedFrameInScreen.isNull {
                    self.lastReportedFrameInScreen = .null
                    self.lastReportedWindow = nil
                    self.onFrameChange?(CGRect.zero, nil)
                }
                return
            }

            let frameInWindow = self.convert(self.bounds, to: nil)
            let frameInScreen = window.convertToScreen(frameInWindow)
            let frameTolerance: CGFloat = 0.5
            let hasLastFrame = !self.lastReportedFrameInScreen.isNull
            let frameChanged = !hasLastFrame ||
                abs(frameInScreen.origin.x - self.lastReportedFrameInScreen.origin.x) > frameTolerance ||
                abs(frameInScreen.origin.y - self.lastReportedFrameInScreen.origin.y) > frameTolerance ||
                abs(frameInScreen.size.width - self.lastReportedFrameInScreen.size.width) > frameTolerance ||
                abs(frameInScreen.size.height - self.lastReportedFrameInScreen.size.height) > frameTolerance
            let windowChanged = self.lastReportedWindow !== window

            guard force || frameChanged || windowChanged else { return }

            self.lastReportedFrameInScreen = frameInScreen
            self.lastReportedWindow = window
            self.onFrameChange?(frameInScreen, window)
        }
    }
}

private final class BottomOverlayHostingView: NSHostingView<BottomOverlayView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        if SettingsStore.shared.overlaySize == .pill {
            let visibleOverlayBounds = self.bounds.insetBy(
                dx: PillShadowMetrics.hitTestInset,
                dy: PillShadowMetrics.hitTestInset
            )
            guard visibleOverlayBounds.contains(point) else { return nil }
        }
        return super.hitTest(point)
    }
}

private struct DynamicPreviewHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = next
        }
    }
}

// MARK: - Bottom Overlay SwiftUI View

struct BottomOverlayView: View {
    @ObservedObject private var contentState = NotchContentState.shared
    @ObservedObject private var appServices = AppServices.shared
    @ObservedObject private var activeAppMonitor = ActiveAppMonitor.shared
    @ObservedObject private var historyStore = TranscriptionHistoryStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Primary text on the floating overlay — adapts for light/dark glass.
    private var overlayPrimaryText: Color {
        self.colorScheme == .dark ? Color.white.opacity(0.9) : AppTheme.VibeBrand.lightInk
    }

    @State private var isHoveringActionsChip = false
    @State private var isHoveringSettingsChip = false
    @State private var actionsSelectorFrameInScreen: CGRect = .zero
    @State private var actionsSelectorWindow: NSWindow?
    @State private var dynamicPreviewMeasuredHeight: CGFloat = 0
    @State private var frozenDynamicPreviewHeight: CGFloat?
    @State private var dynamicPreviewResizeBucket: Int = 0
    @State private var processingStatusVisible = false
    @State private var processingStatusCycleID = 0
    @State private var lastResolvedAppIcon: NSImage?

    struct LayoutConstants {
        let hPadding: CGFloat
        let vPadding: CGFloat
        let waveformWidth: CGFloat
        let waveformHeight: CGFloat
        let iconSize: CGFloat
        let transFontSize: CGFloat
        let modeFontSize: CGFloat
        let cornerRadius: CGFloat
        let barCount: Int
        let barWidth: CGFloat
        let barSpacing: CGFloat
        let minBarHeight: CGFloat
        let maxBarHeight: CGFloat
        let containerWidth: CGFloat
        let overlayWidth: CGFloat
        let overlayHeight: CGFloat
        let previewBoxHeight: CGFloat
        let usesFixedCanvas: Bool
        let showsTopControls: Bool
        let showsPreview: Bool
        let showsModeLabel: Bool

        static func get(for size: SettingsStore.OverlaySize) -> LayoutConstants {
            switch size {
            case .pill:
                return LayoutConstants(
                    hPadding: 12,
                    vPadding: 8,
                    waveformWidth: 56,
                    waveformHeight: 30,
                    iconSize: 18,
                    transFontSize: 10,
                    modeFontSize: 9,
                    cornerRadius: 23,
                    barCount: 11,
                    barWidth: 3.0,
                    barSpacing: 2.2,
                    minBarHeight: 4,
                    maxBarHeight: 34,
                    containerWidth: 100,
                    overlayWidth: 100,
                    overlayHeight: 46,
                    previewBoxHeight: 0,
                    usesFixedCanvas: false,
                    showsTopControls: false,
                    showsPreview: false,
                    showsModeLabel: false
                )
            case .small:
                return LayoutConstants(
                    hPadding: 13,
                    vPadding: 7,
                    waveformWidth: 90,
                    waveformHeight: 20,
                    iconSize: 16,
                    transFontSize: 11,
                    modeFontSize: 10,
                    cornerRadius: 24,
                    barCount: 7,
                    barWidth: 3.8,
                    barSpacing: 3.8,
                    minBarHeight: 5,
                    maxBarHeight: 16,
                    containerWidth: 200,
                    overlayWidth: 300,
                    overlayHeight: 124,
                    previewBoxHeight: 0,
                    usesFixedCanvas: false,
                    showsTopControls: false,
                    showsPreview: true,
                    showsModeLabel: true
                )
            case .medium:
                return LayoutConstants(
                    hPadding: 22,
                    vPadding: 13,
                    waveformWidth: 148,
                    waveformHeight: 36,
                    iconSize: 20,
                    transFontSize: 13,
                    modeFontSize: 12,
                    cornerRadius: 30,
                    barCount: 13,
                    barWidth: 4.2,
                    barSpacing: 3.8,
                    minBarHeight: 5,
                    maxBarHeight: 40,
                    containerWidth: 340,
                    overlayWidth: 380,
                    overlayHeight: 156,
                    previewBoxHeight: 0,
                    usesFixedCanvas: false,
                    // Top chips (Mode / AI Prompt / Actions) removed — keep the clean waveform pill only.
                    showsTopControls: false,
                    showsPreview: true,
                    showsModeLabel: true
                )
            case .large:
                return LayoutConstants(
                    hPadding: 24,
                    vPadding: 14,
                    waveformWidth: 210,
                    waveformHeight: 52,
                    iconSize: 26,
                    transFontSize: 15,
                    modeFontSize: 14,
                    cornerRadius: 34,
                    barCount: 15,
                    barWidth: 5.0,
                    barSpacing: 4.2,
                    minBarHeight: 6,
                    maxBarHeight: 58,
                    containerWidth: 600,
                    overlayWidth: 600,
                    overlayHeight: 288,
                    previewBoxHeight: 92,
                    usesFixedCanvas: true,
                    showsTopControls: false,
                    showsPreview: true,
                    showsModeLabel: true
                )
            }
        }
    }

    private var layout: LayoutConstants {
        LayoutConstants.get(for: self.settings.overlaySize)
    }

    private var isCompactControls: Bool {
        self.settings.overlaySize == .medium
    }

    private var isPillSize: Bool {
        self.settings.overlaySize == .pill
    }

    private var modeColor: Color {
        self.contentState.mode.notchColor
    }

    private var modeLabel: String {
        switch self.contentState.mode {
        case .dictation: return "Dictate"
        }
    }

    private var displayedAppIcon: NSImage? {
        self.contentState.targetAppIcon ?? self.activeAppMonitor.activeAppIcon ?? self.lastResolvedAppIcon
    }

    private var processingLabel: String {
        switch self.contentState.mode {
        case .dictation: return "Transcribing..."
        }
    }

    private static let transientOverlayStatusTexts: Set<String> = [
        "Transcribing",
    ]

    /// ContentView writes transient status strings into transcriptionText while processing
    /// (e.g. "Transcribing"). Prefer that when present.
    private var processingStatusText: String {
        let t = self.contentState.transcriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.transientOverlayStatusTexts.contains(t) else { return self.processingLabel }
        return t
    }

    private var hasTranscription: Bool {
        !self.transcriptionPreviewText.isEmpty
    }

    private var promptSelectorFontSize: CGFloat {
        max(self.layout.modeFontSize - 1, 9)
    }

    private var promptSelectorVerticalPadding: CGFloat {
        5
    }

    private var promptMenuGap: CGFloat {
        max(0, self.layout.vPadding * 0.05)
    }

    private var promptSelectorMaxWidth: CGFloat {
        self.layout.waveformWidth * 1.75
    }

    private var previewMaxHeight: CGFloat {
        self.layout.usesFixedCanvas ? self.layout.previewBoxHeight : self.layout.transFontSize * 4.2
    }

    private var shouldReservePreviewArea: Bool {
        self.layout.showsPreview && self.settings.enableStreamingPreview
    }

    private var overlayFrameHeight: CGFloat? {
        guard self.layout.usesFixedCanvas else { return nil }
        return self.shouldReservePreviewArea ? self.layout.overlayHeight : nil
    }

    private var previewMaxWidth: CGFloat {
        if self.layout.usesFixedCanvas {
            return self.layout.waveformWidth * 2.2
        }

        // Cap the preview to the card's inner content width. The medium preview
        // renders transcription text in a *fixed* `.frame(width: previewMaxWidth)`,
        // so if this exceeds `containerWidth - 2*hPadding` the text forces the whole
        // card wider than its fixed `containerWidth`. The card's glow / animated
        // border / drop shadow then overflow the reserved transparent window margin
        // and clip at the content-sized window edge — the "sides get cut off at
        // medium + live preview + text" bug. `min` keeps the card == containerWidth.
        let innerContentWidth = self.layout.containerWidth - self.layout.hPadding * 2
        return min(self.layout.waveformWidth * 2.2, innerContentWidth)
    }

    private var dynamicPreviewBaseMinHeight: CGFloat {
        guard self.shouldReservePreviewArea else { return 0 }
        let verticalPadding = self.settings.overlaySize == .small
            ? max(2, self.transcriptionVerticalPadding - 1)
            : self.transcriptionVerticalPadding
        return self.estimatedPreviewLineHeight + verticalPadding * 2
    }

    private var effectiveDynamicPreviewLockedHeight: CGFloat? {
        guard self.contentState.isBottomOverlayReleaseTransitioning else { return nil }
        guard let frozenDynamicPreviewHeight else { return nil }
        return max(frozenDynamicPreviewHeight, self.dynamicPreviewBaseMinHeight)
    }

    private var effectiveDynamicPreviewMinHeight: CGFloat {
        self.effectiveDynamicPreviewLockedHeight ?? self.dynamicPreviewBaseMinHeight
    }

    private var estimatedPreviewLineHeight: CGFloat {
        max(self.layout.transFontSize * 1.25, self.layout.transFontSize + 2)
    }

    private var currentPreviewSizingText: String {
        guard self.shouldReservePreviewArea else { return "" }
        if self.shouldShowProcessingPreview {
            return self.processingPreviewText
        }
        return self.shouldShowProcessingStatus ? self.processingStatusText : self.transcriptionPreviewText
    }

    private var shouldShowProcessingStatus: Bool {
        self.shouldReservePreviewArea && self.contentState.isProcessing && self.processingStatusVisible
    }

    private var shouldSuppressPreviewDuringRelease: Bool {
        if self.shouldShowProcessingPreview {
            return false
        }
        return self.contentState.isBottomOverlayReleaseTransitioning || self.contentState.isBottomOverlayDismissing
    }

    private func previewResizeBucket(for previewText: String) -> Int {
        guard self.shouldReservePreviewArea else { return 0 }
        let trimmed = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return self.shouldShowProcessingStatus ? 1 : 0 }

        if self.settings.overlaySize == .small {
            return 1
        }

        let newlineCount = trimmed.filter { $0 == "\n" }.count
        let estimatedCharacterWidth = max(self.layout.transFontSize * 0.56, 1)
        let characterCapacity = max(Int((self.previewMaxWidth / estimatedCharacterWidth).rounded(.down)), 12)
        let estimatedWrappedLines = max(1, (trimmed.count + characterCapacity - 1) / characterCapacity)
        let maxVisibleLines = max(Int((self.previewMaxHeight / max(self.estimatedPreviewLineHeight, 1)).rounded(.down)), 1)
        return min(max(estimatedWrappedLines + newlineCount, 1), maxVisibleLines)
    }

    private func refreshDynamicPreviewSizeIfNeeded(for previewText: String) {
        guard self.shouldReservePreviewArea else { return }
        guard !self.layout.usesFixedCanvas else { return }
        let nextBucket = self.previewResizeBucket(for: previewText)
        guard nextBucket != self.dynamicPreviewResizeBucket else { return }
        self.dynamicPreviewResizeBucket = nextBucket
        BottomOverlayWindowController.shared.refreshSizeForContent()
    }

    private var transcriptionVerticalPadding: CGFloat {
        max(4, self.layout.vPadding / 2)
    }

    private var transcriptionPreviewText: String {
        let preview = self.contentState.cachedPreviewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !self.contentState.isProcessing else { return self.contentState.cachedPreviewText }
        guard Self.transientOverlayStatusTexts.contains(preview) else { return self.contentState.cachedPreviewText }
        return ""
    }

    private var processingPreviewText: String {
        guard self.contentState.isProcessing else { return "" }
        let preview = self.transcriptionPreviewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.transientOverlayStatusTexts.contains(preview) else { return "" }
        return self.transcriptionPreviewText
    }

    private var shouldShowProcessingPreview: Bool {
        !self.processingPreviewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func richPreviewText(_ previewText: String) -> Text {
        Text(previewText)
            .foregroundColor(self.overlayPrimaryText)
    }

    private var overlayAnimatedOffsetY: CGFloat {
        if self.contentState.isBottomOverlayDismissing {
            return self.contentState.bottomOverlayDismissOffsetY
        }
        return 0
    }

    private var overlayAnimatedScale: CGFloat {
        self.contentState.isBottomOverlayDismissing ? 0.985 : 1.0
    }

    private var overlayAnimatedOpacity: Double {
        1.0
    }

    private func chipBackground(isHovered: Bool, disabled: Bool) -> some View {
        let fillColor: Color
        if disabled {
            fillColor = AppTheme.VibeBrand.ground.opacity(0.95)
        } else if isHovered {
            fillColor = AppTheme.VibeBrand.panel3
        } else {
            fillColor = AppTheme.VibeBrand.panel
        }

        let topStrokeOpacity: Double = disabled ? 0.10 : (isHovered ? 0.36 : 0.16)
        let bottomStrokeOpacity: Double = disabled ? 0.06 : (isHovered ? 0.22 : 0.08)
        let hoverShadowColor: Color = (isHovered && !disabled) ? Color.white.opacity(0.16) : .clear

        // Fully-rounded pills for the top controls — cleaner, more premium than
        // the previous squircle.
        return Capsule(style: .continuous)
            .fill(fillColor)
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(topStrokeOpacity),
                                Color.white.opacity(bottomStrokeOpacity),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(disabled ? 0 : 0.18), radius: 3, x: 0, y: 1)
            .shadow(color: hoverShadowColor, radius: 6, x: 0, y: 1)
    }

    private func rememberAppIcon(_ icon: NSImage?) {
        guard let icon else { return }
        self.lastResolvedAppIcon = icon
    }

    private func closeActionsMenu() {
        BottomOverlayActionsMenuController.shared.hide()
    }

    private func handleActionsSelectorHover(_ hovering: Bool) {
        let actionsDisabled = self.historyStore.entries.isEmpty || self.contentState.isProcessing
        guard !actionsDisabled else {
            self.closeActionsMenu()
            return
        }
        BottomOverlayActionsMenuController.shared.selectorHoverChanged(hovering)
    }

    private func handleActionsSelectorFrameChange(_ frameInScreen: CGRect, window: NSWindow?) {
        self.actionsSelectorFrameInScreen = frameInScreen
        self.actionsSelectorWindow = window
        let actionsDisabled = self.historyStore.entries.isEmpty || self.contentState.isProcessing
        guard self.layout.showsTopControls, !actionsDisabled else {
            BottomOverlayActionsMenuController.shared.hide()
            return
        }

        BottomOverlayActionsMenuController.shared.updateAnchor(
            selectorFrameInScreen: frameInScreen,
            parentWindow: window,
            maxWidth: self.promptSelectorMaxWidth,
            menuGap: self.promptMenuGap
        )
    }

    private var actionsSelectorTrigger: some View {
        let actionsDisabled = self.historyStore.entries.isEmpty || self.contentState.isProcessing
        return HStack(spacing: 5) {
            Text("Actions")
                .font(.system(size: self.promptSelectorFontSize, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
            Image(systemName: "chevron.up")
                .font(.system(size: max(self.promptSelectorFontSize - 1, 8), weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 11)
        .padding(.vertical, self.promptSelectorVerticalPadding)
        .background(
            self.chipBackground(
                isHovered: self.isHoveringActionsChip,
                disabled: actionsDisabled
            )
        )
    }

    private var actionsSelectorView: some View {
        let actionsDisabled = self.historyStore.entries.isEmpty || self.contentState.isProcessing
        return self.actionsSelectorTrigger
            .background(
                PromptSelectorAnchorReader { frameInScreen, window in
                    self.handleActionsSelectorFrameChange(frameInScreen, window: window)
                }
                .allowsHitTesting(false)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                self.isHoveringActionsChip = hovering && !actionsDisabled
                self.handleActionsSelectorHover(hovering)
            }
            .onTapGesture {
                guard self.layout.showsTopControls, !actionsDisabled else { return }
                BottomOverlayActionsMenuController.shared.updateAnchor(
                    selectorFrameInScreen: self.actionsSelectorFrameInScreen,
                    parentWindow: self.actionsSelectorWindow,
                    maxWidth: self.promptSelectorMaxWidth,
                    menuGap: self.promptMenuGap
                )
                BottomOverlayActionsMenuController.shared.toggleFromTap()
            }
            .help(
                self.historyStore.entries.isEmpty
                    ? "No saved dictation history available"
                    : "Copy or paste your latest dictation"
            )
    }

    private var settingsChip: some View {
        let disabled = false
        return HStack(spacing: 0) {
            Image(systemName: "gearshape")
                .font(.system(size: max(self.promptSelectorFontSize + 1, 10), weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, self.promptSelectorVerticalPadding)
        .background(
            self.chipBackground(
                isHovered: self.isHoveringSettingsChip,
                disabled: disabled
            )
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            self.isHoveringSettingsChip = hovering
        }
        .onTapGesture {
            self.closeActionsMenu()
            self.contentState.onOpenPreferencesRequested?()
        }
        .help("Open Preferences")
    }

    private func scrollablePreviewText(_ previewText: String) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                self.richPreviewText(previewText)
                    .font(.system(size: self.layout.transFontSize, weight: .medium))
                    .multilineTextAlignment(.leading)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(height: 1).id("bottom")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .onChange(of: previewText) { _, _ in
                DispatchQueue.main.async {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func dynamicPreviewText(_ previewText: String) -> some View {
        if self.settings.overlaySize == .small {
            self.richPreviewText(previewText)
                .font(.system(size: self.layout.transFontSize, weight: .medium))
                .multilineTextAlignment(.leading)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, max(2, self.transcriptionVerticalPadding - 1))
        } else {
            self.richPreviewText(previewText)
                .font(.system(size: self.layout.transFontSize, weight: .medium))
                .multilineTextAlignment(.leading)
                .lineLimit(Int(self.previewMaxHeight / max(self.estimatedPreviewLineHeight, 1)))
                .truncationMode(.head)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: self.previewMaxWidth, alignment: .leading)
                .padding(.vertical, self.transcriptionVerticalPadding)
        }
    }

    var body: some View {
        VStack(spacing: max(4, self.layout.vPadding / 2)) {
            if self.layout.showsTopControls {
                HStack(spacing: self.isCompactControls ? 6 : 8) {
                    Spacer(minLength: 4)
                    self.actionsSelectorView
                    if !self.isCompactControls {
                        self.settingsChip
                    }
                }
                .frame(maxWidth: .infinity, alignment: self.isCompactControls ? .center : .leading)
                .padding(.horizontal, self.layout.hPadding)
            }

            VStack(spacing: self.layout.vPadding / 2) {
                if self.shouldReservePreviewArea {
                    if self.layout.usesFixedCanvas {
                        // Transcription text area (fixed-height in large mode)
                        Group {
                            if self.shouldSuppressPreviewDuringRelease {
                                Color.clear
                            } else if self.shouldShowProcessingPreview {
                                self.scrollablePreviewText(self.processingPreviewText)
                            } else if self.shouldShowProcessingStatus {
                                // Temporarily hidden; the waveform sweep carries processing state.
                                // ShimmerText(
                                //     text: self.processingStatusText,
                                //     color: self.modeColor,
                                //     font: .system(size: self.layout.transFontSize, weight: .medium)
                                // )
                                // .id(self.processingStatusCycleID)
                                // .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                                Color.clear
                            } else if self.contentState.isProcessing {
                                Color.clear
                            } else if self.hasTranscription {
                                let previewText = self.transcriptionPreviewText
                                if !previewText.isEmpty {
                                    ScrollViewReader { proxy in
                                        ScrollView(.vertical, showsIndicators: false) {
                                            Text(previewText)
                                                .font(.system(size: self.layout.transFontSize, weight: .medium))
                                                .foregroundStyle(.white.opacity(0.9))
                                                .multilineTextAlignment(.leading)
                                                .lineLimit(nil)
                                                .fixedSize(horizontal: false, vertical: true)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            Color.clear.frame(height: 1).id("bottom")
                                        }
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                        .clipped()
                                        .onAppear {
                                            DispatchQueue.main.async {
                                                proxy.scrollTo("bottom", anchor: .bottom)
                                            }
                                        }
                                        .onChange(of: previewText) { _, _ in
                                            DispatchQueue.main.async {
                                                proxy.scrollTo("bottom", anchor: .bottom)
                                            }
                                        }
                                    }
                                }
                            } else {
                                Color.clear
                            }
                        }
                        .padding(.vertical, self.transcriptionVerticalPadding)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: self.previewMaxHeight,
                            maxHeight: self.previewMaxHeight,
                            alignment: .topLeading
                        )
                    } else {
                        // Original dynamic preview behavior for small/medium
                        Group {
                            if self.shouldSuppressPreviewDuringRelease {
                                Color.clear
                            } else if self.shouldShowProcessingPreview {
                                self.dynamicPreviewText(self.processingPreviewText)
                            } else if self.hasTranscription && !self.contentState.isProcessing {
                                let previewText = self.transcriptionPreviewText
                                if !previewText.isEmpty {
                                    if self.settings.overlaySize == .small {
                                        Text(previewText)
                                            .font(.system(size: self.layout.transFontSize, weight: .medium))
                                            .foregroundStyle(self.overlayPrimaryText)
                                            .multilineTextAlignment(.leading)
                                            .lineLimit(1)
                                            .truncationMode(.head)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.vertical, max(2, self.transcriptionVerticalPadding - 1))
                                    } else {
                                        Text(previewText)
                                            .font(.system(size: self.layout.transFontSize, weight: .medium))
                                            .foregroundStyle(self.overlayPrimaryText)
                                            .multilineTextAlignment(.leading)
                                            .lineLimit(Int(self.previewMaxHeight / max(self.estimatedPreviewLineHeight, 1)))
                                            .truncationMode(.head)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .frame(width: self.previewMaxWidth, alignment: .leading)
                                            .padding(.vertical, self.transcriptionVerticalPadding)
                                    }
                                }
                            } else if self.shouldShowProcessingStatus {
                                // Temporarily hidden; the waveform sweep carries processing state.
                                // ShimmerText(
                                //     text: self.processingStatusText,
                                //     color: self.modeColor,
                                //     font: .system(size: self.layout.transFontSize, weight: .medium)
                                // )
                                // .id(self.processingStatusCycleID)
                                Color.clear
                            } else if self.contentState.isProcessing {
                                Color.clear
                            } else {
                                Color.clear
                            }
                        }
                        .background(
                            GeometryReader { proxy in
                                Color.clear
                                    .preference(key: DynamicPreviewHeightPreferenceKey.self, value: proxy.size.height)
                            }
                        )
                        .frame(
                            maxWidth: self.previewMaxWidth,
                            minHeight: self.effectiveDynamicPreviewMinHeight,
                            maxHeight: self.effectiveDynamicPreviewLockedHeight
                        )
                    }
                }

                // Waveform + Mode label row
                HStack(spacing: self.layout.hPadding / 1.5) {
                    // Target app icon (the app where text will be typed)
                    let appIcon = self.displayedAppIcon
                    let showModelLoading = self.layout.showsModeLabel && !self.appServices.asr.isAsrReady &&
                        (self.appServices.asr.isLoadingModel || self.appServices.asr.isDownloadingModel)
                    VStack(spacing: 2) {
                        if showModelLoading {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        if let appIcon = appIcon {
                            Image(nsImage: appIcon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: self.layout.iconSize, height: self.layout.iconSize)
                                .clipShape(RoundedRectangle(cornerRadius: self.layout.iconSize / 4))
                        } else if !self.layout.showsModeLabel {
                            Circle()
                                .fill(self.modeColor.opacity(0.9))
                                .frame(width: max(self.layout.iconSize * 0.45, 7), height: max(self.layout.iconSize * 0.45, 7))
                        }
                    }
                    .frame(width: self.layout.iconSize, height: self.layout.iconSize)
                    .opacity((appIcon != nil || showModelLoading || !self.layout.showsModeLabel) ? 1 : 0)

                    // Waveform visualization
                    BottomWaveformView(layout: self.layout)
                        .frame(width: self.layout.waveformWidth, height: self.layout.waveformHeight)

                    // Mode label + model load hint
                    if self.layout.showsModeLabel {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(self.modeLabel)
                                .font(.system(size: self.layout.modeFontSize, weight: .semibold))
                                .foregroundStyle(self.modeColor)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)

                            if !self.appServices.asr.isAsrReady &&
                                (self.appServices.asr.isLoadingModel || self.appServices.asr.isDownloadingModel)
                                && self.settings.overlaySize != .small
                            {
                                Text("Loading model…")
                                    .font(.system(size: max(self.layout.modeFontSize - 2, 9), weight: .medium))
                                    .foregroundStyle(AppTheme.VibeBrand.amber.opacity(0.85))
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, self.layout.hPadding)
            .padding(.vertical, self.layout.vPadding)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(
                VibeOverlayGlassChrome(
                    cornerRadius: self.layout.cornerRadius,
                    reduceMotion: self.reduceMotion,
                    isPill: self.isPillSize
                )
            )
            .frame(maxWidth: .infinity, alignment: .top)
            .transaction { transaction in
                if self.shouldSuppressPreviewDuringRelease {
                    transaction.animation = nil
                }
            }
        }
        .frame(
            width: self.layout.usesFixedCanvas ? self.layout.overlayWidth : self.layout.containerWidth,
            height: self.overlayFrameHeight,
            alignment: .top
        )
        // Small margin for the drop shadow only (was 20–26 with soft bloom — that
        // empty translucent margin read as edge blur once streaming text widened the panel).
        .padding(self.isPillSize ? 12 : 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .scaleEffect(self.overlayAnimatedScale, anchor: .center)
        .offset(y: self.overlayAnimatedOffsetY)
        .opacity(self.overlayAnimatedOpacity)
        .animation(.timingCurve(0.22, 0.0, 0.2, 1.0, duration: 0.02), value: self.contentState.isBottomOverlayDismissing)
        .onChange(of: self.settings.overlaySize) { _, _ in
            self.dynamicPreviewResizeBucket = self.previewResizeBucket(for: self.currentPreviewSizingText)
            self.frozenDynamicPreviewHeight = nil
            BottomOverlayWindowController.shared.refreshSizeForContent()
        }
        .onChange(of: self.settings.enableStreamingPreview) { _, _ in
            self.dynamicPreviewResizeBucket = self.previewResizeBucket(for: self.currentPreviewSizingText)
            self.frozenDynamicPreviewHeight = nil
            BottomOverlayWindowController.shared.refreshSizeForContent()
        }
        .onChange(of: self.contentState.cachedPreviewText) { _, _ in
            self.refreshDynamicPreviewSizeIfNeeded(for: self.currentPreviewSizingText)
        }
        .onChange(of: self.contentState.mode) { _, _ in
            self.closeActionsMenu()
            self.isHoveringActionsChip = false
            self.isHoveringSettingsChip = false
            if !self.layout.usesFixedCanvas {
                self.dynamicPreviewResizeBucket = self.previewResizeBucket(for: self.currentPreviewSizingText)
                BottomOverlayWindowController.shared.refreshSizeForContent()
            }
        }
        .onChange(of: self.contentState.isProcessing) { _, processing in
            self.processingStatusVisible = processing
            if processing {
                self.processingStatusCycleID &+= 1
                self.closeActionsMenu()
            }
            self.isHoveringActionsChip = false
            self.isHoveringSettingsChip = false
            if !self.layout.usesFixedCanvas {
                self.refreshDynamicPreviewSizeIfNeeded(for: self.currentPreviewSizingText)
            }
        }
        .onChange(of: self.processingStatusVisible) { _, _ in
            guard !self.layout.usesFixedCanvas else { return }
            self.refreshDynamicPreviewSizeIfNeeded(for: self.currentPreviewSizingText)
        }
        .onChange(of: self.contentState.isBottomOverlayReleaseTransitioning) { _, transitioning in
            guard self.shouldReservePreviewArea else {
                self.frozenDynamicPreviewHeight = nil
                return
            }
            guard !self.layout.usesFixedCanvas else { return }
            if transitioning {
                let measuredHeight = self.dynamicPreviewMeasuredHeight > 0
                    ? self.dynamicPreviewMeasuredHeight
                    : self.effectiveDynamicPreviewMinHeight
                self.frozenDynamicPreviewHeight = max(measuredHeight, self.dynamicPreviewBaseMinHeight)
            } else {
                self.frozenDynamicPreviewHeight = nil
                BottomOverlayWindowController.shared.refreshSizeForContent()
            }
        }
        .onPreferenceChange(DynamicPreviewHeightPreferenceKey.self) { measuredHeight in
            guard !self.layout.usesFixedCanvas else { return }
            guard measuredHeight > 0 else { return }
            self.dynamicPreviewMeasuredHeight = measuredHeight
        }
        .preferredColorScheme(self.settings.themePreference.preferredColorScheme)
        .onAppear {
            self.rememberAppIcon(self.contentState.targetAppIcon ?? self.activeAppMonitor.activeAppIcon)
            self.dynamicPreviewResizeBucket = self.previewResizeBucket(for: self.currentPreviewSizingText)
        }
        .onReceive(self.contentState.$targetAppIcon) { icon in
            self.rememberAppIcon(icon)
        }
        .onDisappear {
            self.closeActionsMenu()
            self.isHoveringActionsChip = false
            self.isHoveringSettingsChip = false
        }
    }
}

// MARK: - Overlay menu surface (light/dark)

private struct VibeOverlayMenuSurface: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(self.colorScheme == .dark ? Color.black : AppTheme.VibeBrand.lightPanel2)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        self.colorScheme == .dark ? Color.white.opacity(0.12) : AppTheme.VibeBrand.lightLine,
                        lineWidth: 1
                    )
            )
    }
}

// MARK: - Glassmorphic overlay chrome (adaptive light/dark + moving purple border)

/// Premium glass panel with TheVibeFather void tint and a rotating purple neon edge.
/// Supports light and dark (follows the active color scheme).
///
/// Intentionally avoids `Material` / `ultraThinMaterial`. On a floating clear `NSPanel`,
/// Material + compositing/blur/shadow siblings either:
/// 1. lose their rounded fill path and paint a square translucent "film", or
/// 2. bake into a milky solid white card via `compositingGroup()`.
/// A hard-clipped solid stack stays sharp over any desktop.
struct VibeOverlayGlassChrome: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var contentState = NotchContentState.shared

    let cornerRadius: CGFloat
    let reduceMotion: Bool
    var isPill: Bool = false

    private var isDark: Bool { self.colorScheme == .dark }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous)
    }

    private var baseFill: Color {
        self.isDark ? AppTheme.VibeBrand.ground : AppTheme.VibeBrand.lightPanel2
    }

    private var topSheen: Color {
        self.isDark ? AppTheme.VibeBrand.panel.opacity(0.55) : AppTheme.VibeBrand.lightPanel3.opacity(0.9)
    }

    private var edgeStroke: Color {
        self.isDark ? Color.white.opacity(0.12) : AppTheme.VibeBrand.lightLine
    }

    var body: some View {
        // Opaque solid fills only — no materials, no compositing blur, no outer bloom.
        // Animated border runs at a low rate so continuous re-rasterization does not
        // soften the panel edges (especially once streaming text expands the window).
        ZStack {
            self.shape
                .fill(self.baseFill)

            self.shape
                .fill(
                    LinearGradient(
                        colors: [
                            self.topSheen,
                            self.baseFill.opacity(0.0),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            self.shape
                .stroke(self.edgeStroke, lineWidth: 1)

            // Moving purple / pink / blue border — low FPS so text stays sharp
            if self.reduceMotion {
                self.borderStroke(angle: 25)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: !self.contentState.isBottomOverlayPresented)) { timeline in
                    let seconds = timeline.date.timeIntervalSinceReferenceDate
                    let angle = (seconds.truncatingRemainder(dividingBy: 4.0) / 4.0) * 360.0
                    self.borderStroke(angle: angle)
                }
            }
        }
        .clipShape(self.shape)
        .shadow(
            color: Color.black.opacity(self.isDark ? (self.isPill ? 0.40 : 0.32) : 0.12),
            radius: self.isPill ? 4 : 5,
            x: 0,
            y: self.isPill ? 2 : 3
        )
    }

    @ViewBuilder
    private func borderStroke(angle: Double) -> some View {
        self.shape
            .strokeBorder(
                AngularGradient(
                    gradient: Gradient(stops: [
                        .init(color: AppTheme.VibeBrand.voidDeep.opacity(0.20), location: 0.00),
                        .init(color: AppTheme.VibeBrand.voidSoft.opacity(0.95), location: 0.10),
                        .init(color: AppTheme.VibeBrand.pink.opacity(0.90), location: 0.22),
                        .init(color: AppTheme.VibeBrand.void.opacity(0.30), location: 0.40),
                        .init(color: AppTheme.VibeBrand.blue.opacity(0.80), location: 0.58),
                        .init(color: AppTheme.VibeBrand.voidSoft.opacity(0.95), location: 0.78),
                        .init(color: AppTheme.VibeBrand.voidDeep.opacity(0.20), location: 1.00),
                    ]),
                    center: .center,
                    angle: .degrees(angle)
                ),
                lineWidth: 1.25
            )
    }
}

// MARK: - Bottom Waveform View (reads from NotchContentState)

/// GPU-drawn, display-linked waveform for the bottom overlay.
///
/// A single `Canvas` renders every bar in one pass, and one `TimelineView`
/// integrates the bar heights toward the latest audio level with time-based
/// (frame-rate independent) smoothing. This replaces the previous stack of
/// ~40 shadowed/blurred SwiftUI bar views plus a `withAnimation` fired on every
/// audio callback — the source of the overlapping-animation jitter — so motion
/// stays smooth and "native" regardless of how fast the mic tap emits levels.
struct BottomWaveformView: View {
    let layout: BottomOverlayView.LayoutConstants

    @ObservedObject private var contentState = NotchContentState.shared
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Latest audio level (0...1), stored without animation; the timeline eases toward it.
    @State private var targetLevel: CGFloat = 0
    /// Per-bar heights persist across timeline frames in a reference type so the
    /// display-linked closure can advance them without invalidating the view.
    @State private var motion = WaveformMotion()

    private final class WaveformMotion {
        var heights: [CGFloat] = []
        var lastTimestamp: TimeInterval = -1
    }

    private var barCount: Int { self.layout.barCount }
    private var barWidth: CGFloat { self.layout.barWidth }
    private var barSpacing: CGFloat { self.layout.barSpacing }
    private var minHeight: CGFloat { self.layout.minBarHeight }
    private var maxHeight: CGFloat { self.layout.maxBarHeight }

    private var isPillStyle: Bool { !self.layout.showsModeLabel }

    private var isReleaseAnimationActive: Bool {
        self.contentState.isBottomOverlayReleaseTransitioning || self.contentState.isBottomOverlayDismissing
    }

    /// Bars settle flat (silent) during AI processing and the release transition.
    private var isFlatState: Bool {
        self.contentState.isProcessing || self.isReleaseAnimationActive
    }

    /// Keep the tallest bar (plus its glow) inside the clipped canvas bounds.
    private var effectiveMaxHeight: CGFloat {
        let ceiling = self.layout.waveformHeight - 2
        return max(self.minHeight + 1, min(self.maxHeight, ceiling))
    }

    var body: some View {
        // Pause the display link while the (reused) overlay panel is hidden.
        let paused = !self.contentState.isBottomOverlayPresented
        TimelineView(.animation(minimumInterval: self.reduceMotion ? 0.2 : 1.0 / 30.0, paused: paused)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let heights = self.advancedHeights(now: now)
            Canvas { context, size in
                self.draw(context: &context, size: size, heights: heights, now: now)
            }
        }
        .onChange(of: self.contentState.bottomOverlayAudioLevel) { _, level in
            self.targetLevel = min(max(level, 0), 1)
        }
        .onAppear {
            self.targetLevel = self.isFlatState ? 0 : min(max(self.contentState.bottomOverlayAudioLevel, 0), 1)
        }
    }

    // MARK: Motion

    /// Advance each bar toward its target height for this frame and return a snapshot.
    private func advancedHeights(now: TimeInterval) -> [CGFloat] {
        let count = self.barCount
        if self.motion.heights.count != count {
            self.motion.heights = Array(repeating: self.minHeight, count: count)
        }

        var dt: CGFloat = 1.0 / 60.0
        if self.motion.lastTimestamp >= 0 {
            dt = CGFloat(min(max(now - self.motion.lastTimestamp, 0), 0.1))
        }
        self.motion.lastTimestamp = now

        let flat = self.isFlatState
        // Exponential smoothing constant: snappy when live, gentler when settling.
        let tau: CGFloat = flat ? 0.13 : 0.055
        let alpha: CGFloat = dt > 0 ? 1 - CGFloat(exp(Double(-dt / tau))) : 1
        let amplified = flat ? 0 : self.amplifiedLevel()

        for i in 0..<count {
            let target = self.targetHeight(at: i, amplified: amplified, now: now, flat: flat)
            self.motion.heights[i] += (target - self.motion.heights[i]) * alpha
        }
        return self.motion.heights
    }

    private func amplifiedLevel() -> CGFloat {
        let normalized = min(max(self.targetLevel, 0), 1)
        // The Sensitivity slider stores 0.01 ("More") ... 0.8 ("Less"). Map it to a
        // gain rather than a hard cutoff so moving the slider produces a smooth,
        // visible change in how much the bars react. The old threshold-as-floor
        // model gated normal speech to flat bars at the "Less" end and saturated
        // instantly above the floor, so the slider felt like an on/off switch.
        let raw = CGFloat(self.settings.visualizerNoiseThreshold)
        let sensitivity = 1 - min(max((raw - 0.01) / 0.79, 0), 1) // 0 (Less) ... 1 (More)
        // Small fixed noise floor so idle silence stays flat at any sensitivity.
        let gated = max(0, normalized - 0.02)
        let gain = 1.2 + sensitivity * 3.3 // ~1.2x (Less) ... ~4.5x (More)
        return min(1, pow(gated * gain, 0.6))
    }

    private func targetHeight(at index: Int, amplified: CGFloat, now: TimeInterval, flat: Bool) -> CGFloat {
        if flat { return self.minHeight }
        let peak = self.visualizerPeakHeight(at: index)
        // Stronger per-bar variation for a more organic AI wave.
        let variation = 0.78 + 0.28 * abs(sin(CGFloat(index) * 1.73 + amplified * 4.2))
        var height = self.minHeight + (peak - self.minHeight) * amplified * variation

        // Gentle travelling swell while essentially silent so the row feels alive.
        let breathThreshold: CGFloat = 0.08
        if amplified < breathThreshold {
            let quietness = 1 - amplified / breathThreshold
            let wave = sin(now * 2.0 + Double(index) * 0.7)
            let amp = max(self.barWidth * 1.3, 2.2)
            height += amp * CGFloat(0.5 + 0.5 * wave) * quietness
        }
        return min(self.effectiveMaxHeight, max(self.minHeight, height))
    }

    private func visualizerPeakHeight(at index: Int) -> CGFloat {
        let centerDistance = abs(CGFloat(index) - CGFloat(self.barCount - 1) / 2)
        let maxDistance = max(CGFloat(self.barCount - 1) / 2, 1)
        let normalizedDistance = min(centerDistance / maxDistance, 1)
        let factor = max(0.18, 0.96 - normalizedDistance * 0.78)
        return self.minHeight + (self.effectiveMaxHeight - self.minHeight) * factor
    }

    // MARK: Drawing

    private func crownColor(at index: Int, count: Int) -> Color {
        let t = CGFloat(index) / CGFloat(max(count - 1, 1))
        return VibeWaveformStyle.crownColor(t)
    }

    private func draw(context: inout GraphicsContext, size: CGSize, heights: [CGFloat], now: TimeInterval) {
        let count = heights.count
        guard count > 0, size.width > 0, size.height > 0 else { return }

        let midY = size.height / 2
        let totalWidth = CGFloat(count) * self.barWidth + CGFloat(max(count - 1, 0)) * self.barSpacing
        let startX = max(0, (size.width - totalWidth) / 2)
        let ceiling = size.height
        let flat = self.isFlatState
        let processing = self.contentState.isProcessing

        // Pre-compute the bar rectangles (center-anchored capsules).
        var rects = [CGRect](repeating: .zero, count: count)
        for i in 0..<count {
            let x = startX + CGFloat(i) * (self.barWidth + self.barSpacing)
            let h = min(max(heights[i], self.barWidth), ceiling)
            rects[i] = CGRect(x: x, y: midY - h / 2, width: self.barWidth, height: h)
        }

        // Soft crown-tinted glow halo behind the bars (skipped while settling flat).
        if !flat {
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: self.isPillStyle ? 3.5 : 4.5))
                for i in 0..<count {
                    layer.fill(
                        Capsule(style: .continuous).path(in: rects[i]),
                        with: .color(self.crownColor(at: i, count: count).opacity(self.isPillStyle ? 0.5 : 0.6))
                    )
                }
            }
        }

        // Crisp bars.
        for i in 0..<count {
            let rect = rects[i]
            let path = Capsule(style: .continuous).path(in: rect)

            if flat {
                // Dim baseline; a light sweeps across during AI processing.
                context.fill(path, with: .color(AppTheme.VibeBrand.voidSoft.opacity(0.55)))
                if processing {
                    let band = max(size.width * 0.42, 24)
                    let period = 0.95
                    let progress = CGFloat(now.truncatingRemainder(dividingBy: period) / period)
                    let sweepX = progress * (size.width + band) - band / 2
                    let glow = max(0, 1 - abs(rect.midX - sweepX) / band)
                    if glow > 0.02 {
                        context.fill(path, with: .color(self.crownColor(at: i, count: count).opacity(0.85 * glow)))
                    }
                }
            } else {
                let core = self.crownColor(at: i, count: count)
                context.fill(
                    path,
                    with: .linearGradient(
                        Gradient(colors: [core.opacity(0.65), core, Color.white.opacity(0.55)]),
                        startPoint: CGPoint(x: rect.midX, y: rect.maxY),
                        endPoint: CGPoint(x: rect.midX, y: rect.minY)
                    )
                )
                // Hairline top-light for subtle dimensionality.
                context.stroke(path, with: .color(Color.white.opacity(0.20)), lineWidth: 0.5)
            }
        }
    }
}
