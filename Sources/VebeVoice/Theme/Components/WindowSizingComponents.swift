import AppKit
import SwiftUI

struct VibeWindowSizing: Equatable {
    let minWidth: CGFloat
    let minHeight: CGFloat

    var minSize: NSSize {
        NSSize(width: self.minWidth, height: self.minHeight)
    }

    static func minimum(width: CGFloat, height: CGFloat) -> VibeWindowSizing {
        VibeWindowSizing(minWidth: width, minHeight: height)
    }
}

private struct VibeWindowSizingModifier: ViewModifier {
    let sizing: VibeWindowSizing

    func body(content: Content) -> some View {
        content.background(VibeWindowSizingBridge(sizing: self.sizing))
    }
}

private struct VibeWindowSizingBridge: NSViewRepresentable {
    let sizing: VibeWindowSizing

    func makeNSView(context _: Context) -> NSView {
        VibeWindowSizingNSView(sizing: self.sizing)
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        guard let sizingView = nsView as? VibeWindowSizingNSView else { return }
        sizingView.sizing = self.sizing
    }
}

private final class VibeWindowSizingNSView: NSView {
    var sizing: VibeWindowSizing {
        didSet {
            self.applySizing()
        }
    }

    private weak var observedWindow: NSWindow?
    private var resizeObserver: NSObjectProtocol?
    private var isApplyingSizing = false

    init(sizing: VibeWindowSizing) {
        self.sizing = sizing
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    deinit {
        self.removeResizeObserver()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.observeWindowIfNeeded()
        self.applySizing()
    }

    private func observeWindowIfNeeded() {
        guard self.observedWindow !== self.window else { return }

        self.removeResizeObserver()
        self.observedWindow = self.window

        guard let window else { return }
        self.resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.applySizing()
        }
    }

    private func removeResizeObserver() {
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
        self.resizeObserver = nil
    }

    private func applySizing() {
        guard !self.isApplyingSizing, let window else { return }

        self.isApplyingSizing = true
        defer { self.isApplyingSizing = false }

        let minSize = self.sizing.minSize
        window.minSize = minSize

        let frame = window.frame
        guard frame.width < minSize.width || frame.height < minSize.height else { return }

        let targetWidth = max(frame.width, minSize.width)
        let targetHeight = max(frame.height, minSize.height)
        let targetFrame = NSRect(
            x: frame.midX - targetWidth / 2,
            y: frame.midY - targetHeight / 2,
            width: targetWidth,
            height: targetHeight
        )
        window.setFrame(targetFrame, display: true, animate: false)
    }
}

extension View {
    func vibeWindowSizing(_ sizing: VibeWindowSizing) -> some View {
        self.modifier(VibeWindowSizingModifier(sizing: sizing))
    }

    /// Paints the NSWindow chrome (titlebar + frame) with brand purple so the
    /// system gray material does not sit above themed content.
    func vibeWindowChrome(background: Color, isDark: Bool) -> some View {
        self.modifier(VibeWindowChromeModifier(background: background, isDark: isDark))
    }
}

// MARK: - Window chrome (titlebar matches brand purple)

private struct VibeWindowChromeModifier: ViewModifier {
    let background: Color
    let isDark: Bool

    func body(content: Content) -> some View {
        content.background(
            VibeWindowChromeBridge(background: self.background, isDark: self.isDark)
        )
    }
}

private struct VibeWindowChromeBridge: NSViewRepresentable {
    let background: Color
    let isDark: Bool

    func makeNSView(context _: Context) -> NSView {
        VibeWindowChromeNSView(background: self.background, isDark: self.isDark)
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        guard let chromeView = nsView as? VibeWindowChromeNSView else { return }
        chromeView.background = self.background
        chromeView.isDark = self.isDark
        chromeView.applyChrome()
    }
}

private final class VibeWindowChromeNSView: NSView {
    var background: Color
    var isDark: Bool
    private var becomeKeyObserver: NSObjectProtocol?
    private var didUpdateObserver: NSObjectProtocol?
    private weak var observedWindow: NSWindow?

    init(background: Color, isDark: Bool) {
        self.background = background
        self.isDark = isDark
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    deinit {
        self.removeObservers()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.observeWindowIfNeeded()
        self.applyChrome()
        // SwiftUI often re-applies the default title after first layout — stamp again.
        DispatchQueue.main.async { [weak self] in
            self?.applyChrome()
        }
    }

    private func observeWindowIfNeeded() {
        guard self.observedWindow !== self.window else { return }
        self.removeObservers()
        self.observedWindow = self.window
        guard let window else { return }

        self.becomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.applyChrome()
        }

        // Catch SwiftUI clobbering titleVisibility after toolbar updates.
        self.didUpdateObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self, let window = self.window else { return }
            if window.titleVisibility != .hidden {
                window.titleVisibility = .hidden
            }
        }
    }

    private func removeObservers() {
        if let becomeKeyObserver {
            NotificationCenter.default.removeObserver(becomeKeyObserver)
        }
        if let didUpdateObserver {
            NotificationCenter.default.removeObserver(didUpdateObserver)
        }
        self.becomeKeyObserver = nil
        self.didUpdateObserver = nil
        self.observedWindow = nil
    }

    func applyChrome() {
        guard let window else { return }

        // Keep a stable title string for main-window detection, but never show it.
        if window.title.isEmpty || window.title == "main" {
            window.title = "VebeVoice"
        }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = true
        window.backgroundColor = NSColor(self.background)

        // Hide any leftover title label SwiftUI still drops into the titlebar.
        self.hideTitlebarTextFields(in: window)
        // Drop system sidebar-toggle toolbar items — collapser lives in the sidebar.
        self.stripSystemSidebarToggle(from: window)

        // Keep traffic lights usable; do not force fullSizeContentView — that
        // shifts layout under the titlebar and fights NavigationSplitView.
        if window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.remove(.fullSizeContentView)
        }

        window.appearance = NSAppearance(named: self.isDark ? .darkAqua : .aqua)
    }

    private func stripSystemSidebarToggle(from window: NSWindow) {
        guard let toolbar = window.toolbar else { return }
        let removable = toolbar.items.filter { item in
            let id = item.itemIdentifier.rawValue.lowercased()
            // SwiftUI / AppKit identifiers for the built-in sidebar toggle.
            if id.contains("sidebar") { return true }
            if item.image?.name()?.contains("sidebar") == true { return true }
            return false
        }
        for item in removable {
            toolbar.removeItem(at: toolbar.items.firstIndex(of: item)!)
        }
    }

    private func hideTitlebarTextFields(in window: NSWindow) {
        guard let titlebarContainer = window.standardWindowButton(.closeButton)?.superview?.superview else {
            return
        }
        self.hideTextFields(in: titlebarContainer)
    }

    private func hideTextFields(in view: NSView) {
        for subview in view.subviews {
            if let textField = subview as? NSTextField {
                let value = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if value == "VebeVoice" || value.isEmpty == false && window?.title == value {
                    textField.isHidden = true
                    textField.stringValue = ""
                    textField.alphaValue = 0
                }
            }
            self.hideTextFields(in: subview)
        }
    }
}
