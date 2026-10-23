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
        XCTAssertNil(plist["com.apple.security.network.client"],
                     "all runtime model resources are bundled in the Store build")
    }

    func testStoreNoticeCoversEveryBundledModel() throws {
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
                section.contains("**How it reaches you:** **BUNDLED.**"),
                "Store notice must describe bundled \(family) models"
            )
        }
    }

    func testStoreBuildBundlesEveryReachableModel() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(
            contentsOf: root.appendingPathComponent("Scripts/build-mas.sh"),
            encoding: .utf8
        )
        let expected = DeepSearchLevel.allCases.compactMap(\.modelName) + [
            "openvision-tiny-p8-image",
            "openvision-tiny-p8-text",
        ]
        let modelList = expected.joined(separator: " ")
        let declaration = "MAS_BUNDLE_MODELS=\"${MAS_BUNDLE_MODELS:-\(modelList)}\""
        XCTAssertTrue(
            script.contains(declaration),
            "the Store package must include every selectable text tier and both image towers"
        )
        XCTAssertFalse(script.contains("MAS_BUNDLE_MODELS=\"${MAS_BUNDLE_MODELS:-embeddinggemma"))
        XCTAssertTrue(script.contains("cp \"$PRIVACY_MANIFEST\""))
    }

    #if APP_STORE
    func testMissingStoreModelFailsWithoutDownloading() async {
        do {
            _ = try await ModelAssets.ensure("definitely-not-in-the-reviewed-bundle")
            XCTFail("a missing Store model must fail closed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("missing from this App Store installation"))
        }
    }
    #endif
}
