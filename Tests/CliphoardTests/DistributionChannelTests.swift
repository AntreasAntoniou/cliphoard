import XCTest
@testable import Cliphoard

final class DistributionChannelTests: XCTestCase {
    func testCompileTimeChannelIsInternallyConsistent() {
        #if APP_STORE
        XCTAssertTrue(DistributionChannel.isAppStore)
        XCTAssertFalse(DistributionChannel.supportsAutomaticPaste)
        XCTAssertFalse(DistributionChannel.canDiscoverExternalStores)
        #else
        XCTAssertFalse(DistributionChannel.isAppStore)
        XCTAssertTrue(DistributionChannel.supportsAutomaticPaste)
        XCTAssertTrue(DistributionChannel.canDiscoverExternalStores)
        #endif
        XCTAssertTrue(DistributionChannel.manualPasteMessage.contains("⌘V"))
    }

    func testStoreEntitlementsStayMinimalAndSandboxed() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Scripts/Cliphoard-MAS.entitlements"))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any]
        )
        XCTAssertEqual(plist["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(plist["com.apple.security.files.user-selected.read-write"] as? Bool, true)
        XCTAssertNil(plist["com.apple.security.temporary-exception.apple-events"])
        XCTAssertNil(plist["com.apple.security.automation.apple-events"])
        XCTAssertEqual(plist["com.apple.security.network.client"] as? Bool, true,
                       "optional speech weights are downloaded only after explicit preparation")
        XCTAssertEqual(plist["com.apple.security.files.bookmarks.app-scope"] as? Bool, true)
        XCTAssertNil(plist["com.apple.security.network.server"])
    }

    func testStoreNoticeDescribesModelsAsDownloads() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let notice = try String(
            contentsOf: root.appendingPathComponent("THIRD-PARTY-NOTICES-MAS.md"),
            encoding: .utf8
        )
        let headings = [
            "open-ogma-micro, open-ogma-small (Axiotic, \"ogma-libre\")",
            "all-MiniLM-L6-v2 (sentence-transformers) — High tier",
            "OpenVision-Tiny (UCSC-VLAA) — image understanding",
        ]
        for family in headings {
            let section = try XCTUnwrap(
                notice.components(separatedBy: "### \(family)").dropFirst().first,
                "missing Store notice for \(family)"
            ).components(separatedBy: "\n### ").first ?? ""
            XCTAssertTrue(
                section.contains("NOT bundled"),
                "Store notice must describe downloaded \(family) models"
            )
        }
    }

    func testStoreBuildRejectsBundledWeightsAndRetainsPrivacyManifest() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("Scripts/build-mas.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("audit-no-models.py"))
        XCTAssertTrue(script.contains("--check-environment"))
        XCTAssertFalse(script.contains("coremlcompiler"))
        XCTAssertFalse(script.contains("embed-media-model.sh"))
        XCTAssertTrue(script.contains("cp \"$PRIVACY_MANIFEST\""))
    }

    #if APP_STORE
    func testUnknownStoreModelFailsBeforeDownloading() async {
        do {
            _ = try await ModelAssets.ensure("definitely-not-in-the-reviewed-bundle")
            XCTFail("a missing Store model must fail closed")
        } catch {
            guard case ModelAssets.Failure.unknownModel = error else {
                return XCTFail("unknown model must fail before network access: \(error)")
            }
        }
    }
    #endif
}
