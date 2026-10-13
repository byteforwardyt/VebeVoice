import XCTest

final class MicrophoneEntitlementTests: XCTestCase {
    func testHardenedRuntimeBuildDeclaresMicrophoneInputEntitlement() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // VebeVoiceDictationIntegrationTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
        let entitlementURL = repositoryRoot.appendingPathComponent("VebeVoice.entitlements")
        let data = try Data(contentsOf: entitlementURL)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        XCTAssertEqual(
            propertyList["com.apple.security.device.audio-input"] as? Bool,
            true,
            "Hardened Runtime builds must explicitly request microphone input."
        )
    }
}
