import XCTest
@testable import Cliphoard

final class ModelRestorationTests: XCTestCase {
    private func physicalTemporaryRoot() -> URL {
        let path = FileManager.default.temporaryDirectory.path
        return URL(fileURLWithPath: path.hasPrefix("/var/") ? "/private" + path : path, isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
    }
    func testMissingCacheRestoreDoesNotCreateDirectory() async throws {
        let root = physicalTemporaryRoot()
        do { _ = try ModelAssets.restoreCached("openvision-tiny-p8", root: root); XCTFail("missing accepted") }
        catch { XCTAssertFalse(FileManager.default.fileExists(atPath: root.path)) }
    }
    func testDeclineAndCancelSurviveNewPreferenceReaderAndOverrideLegacyConsent() {
        let name = "ModelRestorationTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "imageUnderstandingEnabled")
        XCTAssertTrue(ModelRestorationPreferences.authorized(.pictures, defaults: defaults))
        ModelRestorationPreferences.deferPreparation(.pictures, defaults: defaults)
        XCTAssertFalse(ModelRestorationPreferences.authorized(.pictures, defaults: UserDefaults(suiteName: name)!))
        ModelRestorationPreferences.completed(.pictures, defaults: defaults)
        XCTAssertTrue(ModelRestorationPreferences.authorized(.pictures, defaults: defaults))
        ModelRestorationPreferences.deferPreparation(.pictures, defaults: defaults)
        XCTAssertFalse(ModelRestorationPreferences.authorized(.pictures, defaults: defaults))
    }
    func testCachePresenceAloneDoesNotAuthorizePictures() {
        let name = "ModelRestorationTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(ModelRestorationPreferences.authorized(.pictures, defaults: defaults))
    }
}

extension ModelRestorationTests {
    func testValidReceiptRestoresBothTowersWithoutChangingBytesAndRejectsDamage() throws {
        let fm = FileManager.default
        let root = physicalTemporaryRoot()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let archive = root.appendingPathComponent("fixture.zip")
        try Data("abc".utf8).write(to: archive)
        let sha = ModelAssets.sha256Hex(ofFileAt: archive)!
        let artifact = ModelAssets.Artifact(repository: nil, revision: nil, path: "fixture.zip", bytes: 3,
            sha256: sha, models: ["fixture-image", "fixture-text"], tokenizer: "fixture")
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let platform = ProcessInfo.processInfo.operatingSystemVersionString + "-" + arch
        let platformFile = root.appendingPathComponent("platform")
        try Data(platform.utf8).write(to: platformFile)
        let hash = ModelAssets.sha256Hex(ofFileAt: platformFile)!
        try fm.removeItem(at: platformFile)
        let cache = root.appendingPathComponent("prepared-v1-\(sha)-\(hash.prefix(16))")
        let tokenizer = cache.appendingPathComponent("fixture-tokenizer")
        try fm.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        let json = tokenizer.appendingPathComponent("tokenizer.json")
        try Data("{}".utf8).write(to: json)
        var inventory: [String: [String: String]] = [:]
        for model in artifact.models {
            let folder = cache.appendingPathComponent(model + ".mlmodelc")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let weights = folder.appendingPathComponent("weights")
            try Data("synthetic".utf8).write(to: weights)
            inventory[model] = [model + ".mlmodelc/weights": ModelAssets.sha256Hex(ofFileAt: weights)!,
                "fixture-tokenizer/tokenizer.json": ModelAssets.sha256Hex(ofFileAt: json)!]
        }
        let receipt = cache.appendingPathComponent("receipt.json")
        let data = try JSONSerialization.data(withJSONObject: ["archiveSHA256": sha, "platform": platform, "models": inventory])
        try data.write(to: receipt)
        let modified = try fm.attributesOfItem(atPath: receipt.path)[.modificationDate] as! Date
        let found = try ModelAssets.restoreCachedArtifact(artifact, archive: archive, root: root)
        XCTAssertEqual(found.compiledModel.lastPathComponent, "fixture-image.mlmodelc")
        XCTAssertNotNil(ModelAssets.locate("fixture-image"))
        XCTAssertNotNil(ModelAssets.locate("fixture-text"))
        XCTAssertEqual(try Data(contentsOf: receipt), data)
        XCTAssertEqual(try fm.attributesOfItem(atPath: receipt.path)[.modificationDate] as? Date, modified)
        try Data("damaged".utf8).write(to: cache.appendingPathComponent("fixture-text.mlmodelc/weights"))
        XCTAssertThrowsError(try ModelAssets.restoreCachedArtifact(artifact, archive: archive, root: root))
        XCTAssertNil(ModelAssets.locate("fixture-text"))
        // An intact tower does not imply the other damaged tower was re-published.
        XCTAssertThrowsError(try ModelAssets.restoreCachedArtifact(artifact, archive: archive, root: root))
    }
}

extension ModelRestorationTests {
    func testAdmissionGatesAndSelectedModelDeferrals() {
        let name = "ModelRestorationTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("all", forKey: "searchModality")
        defaults.set(true, forKey: "searchAudioEnabled")
        defaults.set(false, forKey: "searchImagesEnabled")
        defaults.set(false, forKey: "searchVideoEnabled")
        defaults.set("sampled", forKey: "mediaSpeechCoverage")
        defaults.set("small", forKey: "mediaSpeechModel")
        func plan(_ pro: Bool = true, _ safe: Bool = false, _ complete: Bool = true) -> [SearchModelRequirement] {
            ModelRestorationPolicy.requirements(pro: pro, safeMode: safe, storageComplete: complete, defaults: defaults)
        }
        XCTAssertEqual(Set(plan()), Set([.media, .speech(.small)]))
        XCTAssertTrue(plan(false).isEmpty)
        XCTAssertTrue(plan(true, true).isEmpty)
        XCTAssertTrue(plan(true, false, false).isEmpty)
        ModelRestorationPreferences.deferPreparation(.media, defaults: defaults)
        XCTAssertEqual(plan(), [.speech(.small)])
        defaults.set("off", forKey: "mediaSpeechCoverage")
        XCTAssertTrue(plan().isEmpty)
        defaults.set(true, forKey: "imageUnderstandingEnabled")
        XCTAssertEqual(plan(), [.pictures])
        defaults.set(false, forKey: "imageUnderstandingEnabled")
        XCTAssertTrue(plan().isEmpty)
    }
}

extension ModelRestorationTests {
    @MainActor func testSerialSequenceRechecksAdmissionAndCancellationAfterPictures() async {
        var events: [String] = []
        var allowed = true
        await ModelRestorationSequence.run(allowed: { allowed }, pictures: {
            events.append("pictures"); await Task.yield(); allowed = false
        }, media: { events.append("media") })
        XCTAssertEqual(events, ["pictures"])
        events = []
        let task = Task { @MainActor in
            await ModelRestorationSequence.run(allowed: { true }, pictures: {
                events.append("pictures"); try? await Task.sleep(nanoseconds: 30_000_000)
            }, media: { events.append("media") })
        }
        await Task.yield(); task.cancel(); await task.value
        XCTAssertFalse(events.contains("media"))
        events = []
        await ModelRestorationSequence.run(allowed: { true }, pictures: {
            events.append("pictures-start"); await Task.yield(); events.append("pictures-end")
        }, media: { events.append("media"); events.append("speech") })
        XCTAssertEqual(events, ["pictures-start", "pictures-end", "media", "speech"])
    }
    @MainActor func testMediaSingleFlightSerialSpeechAndLiveDeselection() async throws {
        let name = "ModelRestorationTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("all", forKey: "searchModality")
        defaults.set(true, forKey: "searchAudioEnabled")
        defaults.set(false, forKey: "searchImagesEnabled")
        defaults.set(false, forKey: "searchVideoEnabled")
        defaults.set("sampled", forKey: "mediaSpeechCoverage")
        defaults.set("small", forKey: "mediaSpeechModel")
        let directory = physicalTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipStore(directory: directory)
        store.entitlement = .pro(orderID: "synthetic-fixture", issued: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(store.safeMode)
        var events: [String] = []
        let media = MediaSearchController(store: store, defaults: defaults, restorationHooks: .init(media: {
            events.append("media-start"); try await Task.sleep(nanoseconds: 30_000_000); events.append("media-end"); return []
        }, speech: { _ in events.append("speech") }))
        media.restorePreviouslySelectedModels(); media.restorePreviouslySelectedModels()
        await media.waitForCurrentPreparation()
        XCTAssertEqual(events, ["media-start", "media-end", "speech"])
        XCTAssertTrue(media.prepared)
        XCTAssertEqual(media.preparedSpeechModel, .small)
        XCTAssertTrue(store.items.isEmpty)
        events = []
        let stale = MediaSearchController(store: store, defaults: defaults, restorationHooks: .init(media: {
            events.append("started"); try await Task.sleep(nanoseconds: 30_000_000); defaults.set(false, forKey: "searchAudioEnabled"); return []
        }, speech: { _ in events.append("speech") }))
        stale.restorePreviouslySelectedModels(); await stale.waitForCurrentPreparation()
        XCTAssertFalse(stale.prepared); XCTAssertNil(stale.preparedSpeechModel)
        XCTAssertEqual(events, ["started"])
        defaults.set(true, forKey: "searchAudioEnabled")
        let cancelled = MediaSearchController(store: store, defaults: defaults, restorationHooks: .init(media: {
            try await Task.sleep(nanoseconds: 30_000_000); return []
        }, speech: { _ in XCTFail("speech after cancellation") }))
        cancelled.restorePreviouslySelectedModels(); await Task.yield(); cancelled.cancel()
        await cancelled.waitForCurrentPreparation()
        XCTAssertFalse(cancelled.prepared)
        XCTAssertFalse(ModelRestorationPreferences.authorized(.media, defaults: defaults))
    }
}
