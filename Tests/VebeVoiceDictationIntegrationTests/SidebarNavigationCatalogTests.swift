@testable import VebeVoice
import XCTest

/// Structural tests for the shipped sidebar catalog and Settings page scopes.
/// These assert the real `SidebarNavigationCatalog` / `SettingsPageScope` types
/// used by ContentView — not a reimplemented stub.
@MainActor
final class SidebarNavigationCatalogTests: XCTestCase {
    func testSidebarSectionsAreMoreGranularThanLegacyFourBlockLayout() {
        let sectionIDs = SidebarNavigationCatalog.sections.map(\.id)
        XCTAssertEqual(sectionIDs, ["setup", "tools", "activity", "help"])
        // Titles group by job-to-be-done (not Configure/Use).
        let titles = SidebarNavigationCatalog.sections.map(\.title)
        XCTAssertEqual(titles, ["Setup", "Tools", "Activity", "Help"])
        XCTAssertGreaterThanOrEqual(SidebarNavigationCatalog.allItems.count, 12)
    }

    func testMeetingToolsIsListedInToolsSection() {
        let tools = SidebarNavigationCatalog.sections.first { $0.id == "tools" }
        XCTAssertNotNil(tools)
        let items = tools?.entries.map(\.item) ?? []
        XCTAssertTrue(items.contains(.meetingTools))
    }

    func testHotkeysAndOverlayAreTopLevelSetupDestinations() {
        let setup = SidebarNavigationCatalog.sections.first { $0.id == "setup" }
        XCTAssertNotNil(setup)
        let items = setup?.entries.map(\.item) ?? []
        let titles = setup?.entries.map(\.title) ?? []
        XCTAssertTrue(items.contains(.keyboardShortcuts), "Shortcuts must be promoted out of mega-Settings")
        XCTAssertTrue(items.contains(.overlaySettings), "Overlay must be promoted out of mega-Settings")
        XCTAssertTrue(items.contains(.preferences), "General remains reachable")
        // One-word labels
        XCTAssertTrue(titles.contains("Shortcuts"))
        XCTAssertTrue(titles.contains("Engine"))
        XCTAssertTrue(titles.contains("Enhancement"))
        XCTAssertTrue(titles.contains("Dictionary"))
        // Order: General before shortcuts/overlay so Setup scans like System Settings.
        guard
            let generalIdx = items.firstIndex(of: .preferences),
            let shortcutsIdx = items.firstIndex(of: .keyboardShortcuts),
            let overlayIdx = items.firstIndex(of: .overlaySettings)
        else {
            return XCTFail("Missing setup destinations")
        }
        XCTAssertLessThan(generalIdx, shortcutsIdx)
        XCTAssertLessThan(shortcutsIdx, overlayIdx)
    }

    func testToolsUseOneWordLabels() {
        let tools = SidebarNavigationCatalog.sections.first { $0.id == "tools" }
        let titles = tools?.entries.map(\.title) ?? []
        XCTAssertEqual(titles, ["Transcription", "Playground"])
    }

    func testPlaygroundAndDebugAreTopLevelDestinations() {
        let tools = SidebarNavigationCatalog.sections.first { $0.id == "tools" }
        let help = SidebarNavigationCatalog.sections.first { $0.id == "help" }
        XCTAssertTrue(tools?.entries.map(\.item).contains(.testPlayground) == true)
        XCTAssertTrue(help?.entries.map(\.item).contains(.debug) == true)
        XCTAssertEqual(help?.entries.map(\.title), ["Start", "Debug"])
    }

    func testSettingsPageTitlesAreOneWord() {
        XCTAssertEqual(SettingsPageScope.general.pageTitle, "General")
        XCTAssertEqual(SettingsPageScope.keyboardShortcuts.pageTitle, "Shortcuts")
        XCTAssertEqual(SettingsPageScope.overlay.pageTitle, "Overlay")
        XCTAssertEqual(SettingsPageScope.debug.pageTitle, "Debug")
    }

    func testEveryCatalogItemIsDistinct() {
        let items = SidebarNavigationCatalog.allItems
        XCTAssertEqual(items.count, Set(items).count, "Sidebar must not list the same destination twice")
    }

    func testSettingsPageScopesCoverPromotedDestinations() {
        let scopes = SettingsPageScope.allCases
        XCTAssertTrue(scopes.contains(.general))
        XCTAssertTrue(scopes.contains(.keyboardShortcuts))
        XCTAssertTrue(scopes.contains(.overlay))
        XCTAssertFalse(SettingsPageScope.general.pageTitle.isEmpty)
        XCTAssertFalse(SettingsPageScope.keyboardShortcuts.pageSubtitle.isEmpty)
        XCTAssertEqual(SettingsPageScope.overlay.pageTitle, "Overlay")
    }
}
