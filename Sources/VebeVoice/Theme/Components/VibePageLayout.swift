import SwiftUI

/// Canonical page chrome used by Custom Dictionary and applied app-wide.
/// Wide, left-aligned content column with generous padding — not a narrow centered card stack.
enum VibePageLayout {
    /// Content column width (matches Custom Dictionary).
    static let contentMaxWidth: CGFloat = 860

    /// Outer page padding — theme xl (20).
    static let contentPadding: CGFloat = 20

    /// Vertical spacing between major page blocks.
    static let sectionSpacing: CGFloat = 28
}

extension View {
    /// Constrains scroll content to the standard wide page column, centered on large screens.
    func vibePageContentColumn() -> some View {
        self
            .frame(maxWidth: VibePageLayout.contentMaxWidth, alignment: .leading)
            .padding(VibePageLayout.contentPadding)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// Standard vertical page scroll used by most main-window destinations.
struct VibePageScrollView<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: VibePageLayout.sectionSpacing) {
                self.content()
            }
            .vibePageContentColumn()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Shared page header (same on every main tab)

/// Trailing page actions (import/export, close, etc.). Titles live in the sidebar.
struct VibePageHeader<Trailing: View>: View {
    @ViewBuilder var trailing: () -> Trailing

    @ViewBuilder
    var body: some View {
        // Sidebar already names the tab — skip title/subtitle entirely.
        if Trailing.self != EmptyView.self {
            HStack(alignment: .center, spacing: 12) {
                Spacer(minLength: 0)
                self.trailing()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.bottom, 4)
        }
    }
}
