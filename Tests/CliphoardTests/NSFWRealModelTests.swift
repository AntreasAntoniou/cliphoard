import XCTest
import AppKit
@testable import Cliphoard

/// Opt-in qualification against the user's existing, hash-verified downloads.
/// This small synthetic corpus is a regression screen, not an accuracy benchmark.
final class NSFWRealModelTests: XCTestCase {
    private func roots() throws -> (URL, URL, URL) {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["CLIPHOARD_CONTENT_MODEL_ROOT"], let fixtures = env["CLIPHOARD_CONTENT_FIXTURES"] else {
            throw XCTSkip("Set CLIPHOARD_CONTENT_MODEL_ROOT and CLIPHOARD_CONTENT_FIXTURES for actual-model qualification")
        }
        let root = URL(fileURLWithPath: base)
        return (root.appendingPathComponent("Ditto/models"), root.appendingPathComponent("Cliphoard/Models/EmbeddingGemma2"), URL(fileURLWithPath: fixtures))
    }
    func testActualOpenVisionTextAndImageScreen() async throws {
        let (images, media, fixtures) = try roots()
        try await ModelAssets.ensureImageModels(allowDownload: false, root: images)
        let model = try XCTUnwrap(CLIPEmbedder.load())
        let positive = NSFWDetection.positivePrompts.map { CLIPEmbedder.centred(model.embed(text: $0), by: CLIPTextMean.vector) }
        let negative = NSFWDetection.negativePrompts.map { CLIPEmbedder.centred(model.embed(text: $0), by: CLIPTextMean.vector) }
        let evaluator = NSFWModelEvaluator(imageRoot: images, mediaDirectory: media)
        let rows: [(String, Bool)] = [
            ("explicit nude sexual content", true),
            ("sexually explicit pornography", true),
            ("An adult video showing people having sex", true),
            ("A close up photo of exposed genitals", true),
            ("Quarterly budget spreadsheet and meeting minutes", false),
            ("A cat sleeping on a sofa", false),
            ("Medical anatomy textbook for nursing students", false),
            ("Breast cancer screening appointment", false),
            ("A couple kissing at their wedding", false),
            ("A nude figure drawing in an art history textbook", false),
            ("A beach holiday with friends in swimsuits", false),
            ("Python function that parses a text file", false),
            ("A hardcore adult scene with sexual intercourse", true),
            ("Naked adults engaged in oral sex", true),
            ("Sex education lesson about contraception", false),
            ("An artist sketching a marble statue", false),
            ("A kitten curled up asleep on a cushion", false),
            ("A nurse explaining a breast examination", false)
        ]
        for (text, expected) in rows {
            let v = CLIPEmbedder.centred(model.embed(text: text), by: CLIPTextMean.vector)
            XCTAssertEqual(v.count, CLIPEmbedder.dimension)
            let yes = positive.map { SemanticRanker.cosine(v, $0) }.max()!
            let no = negative.map { SemanticRanker.cosine(v, $0) }.max()!
            let result = try await evaluator.text(text)
            print("NSFW_CAL text=\(text) imageTowerYes=\(yes) imageTowerNo=\(no) expected=\(expected) actual=\(result)")
            XCTAssertEqual(result, expected, text)
        }
        let image = try Data(contentsOf: fixtures.appendingPathComponent("ordinary.png"))
        XCTAssertEqual(model.embed(imageData: image).count, CLIPEmbedder.dimension)
        let imageMatch = try await evaluator.image(image)
        XCTAssertFalse(imageMatch, "Ordinary geometric test image must not be flagged")
        await evaluator.reset()
    }
    func testActualMultimodalAudioVideoAndCancellation() async throws {
        let (images, media, fixtures) = try roots()
        let evaluator = NSFWModelEvaluator(imageRoot: images, mediaDirectory: media)
        let cache = fixtures.appendingPathComponent("runtime-cache")
        for file in ["ordinary.wav", "ordinary.mp4"] {
            let result = try await evaluator.media(fixtures.appendingPathComponent(file), video: true, audio: true, cache: cache, admit: { true })
            print("NSFW_CAL media=\(file) expected=false actual=\(result)")
            XCTAssertFalse(result, file)
        }
        let labelledAudio = try await evaluator.media(fixtures.appendingPathComponent("labelled.wav"), video: false, audio: true, cache: cache, admit: { true })
        print("NSFW_CAL media=labelled.wav expected=true actual=\(labelledAudio)")
        XCTAssertTrue(labelledAudio, "Spoken explicit-content label must reach the audio model")
        do {
            _ = try await evaluator.media(fixtures.appendingPathComponent("ordinary.mp4"), video: true, audio: true, cache: cache, admit: { false })
            XCTFail("Revoked admission must not run media inference")
        } catch NSFWModelEvaluator.Failure.stale { }
        await evaluator.reset()
    }
}
