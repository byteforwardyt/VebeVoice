import Foundation

enum AppNavigationDestination {
    case history
    case keyboardShortcuts
    case overlaySettings
}

@MainActor
final class AppNavigationRouter {
    static let shared = AppNavigationRouter()

    private var pendingDestination: AppNavigationDestination?

    private init() {}

    func consumePendingDestination() -> AppNavigationDestination? {
        let destination = self.pendingDestination
        self.pendingDestination = nil
        return destination
    }
}

extension Notification.Name {
    static let appNavigationRequested = Notification.Name("AppNavigationRequested")
}
