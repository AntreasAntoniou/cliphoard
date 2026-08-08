import Foundation
import Vision

/// On-device image understanding: text recognition plus a perceptual feature print,
/// both from Apple's Vision framework. No model is bundled and nothing is downloaded —
/// this is the reason images can become searchable without adding a byte to the app.
///
/// The design is "images become text clips": whatever text is recognised flows into the
/// EXISTING embedder, derived-tag and search pipeline through one case in
/// `SemanticRanker.searchText`, rather than standing up a parallel image index with its
/// own ranking, fusion weights and mode selector. The feature print is separate and
/// answers a different question — "more like this one" — and never mixes with text.
enum ImageUnderstanding {

    /// What one pass over an image yields.
    struct Result: Equatable {
        /// Recognised text, joined by newlines. Empty when the image holds none.
        var text: String
        /// L2-normalised perceptual vector, or empty when the print could not be made.
        var featurePrint: [Float]
        /// Which `VNGenerateImageFeaturePrintRequest` revision produced the print, so a
        /// future revision can be selected for and recomputed instead of being guessed at.
        var featurePrintRevision: Int

        static let empty = Result(text: "", featurePrint: [], featurePrintRevision: 0)
    }

    /// Pinned deliberately, and pinned to the best revision THIS OS has rather than to a
    /// constant. `VNGenerateImageFeaturePrintRequest` defaults to the newest available,
    /// so accepting the default means a future macOS silently starts producing vectors
    /// from a different space and comparing them against stored ones — a similarity
    /// feature that quietly stops working, with no error anywhere.
    ///
    /// The revisions are NOT interchangeable: revision 1 emits 2048 floats, revision 2
    /// emits 768, and revision 2 requires macOS 14 while this package supports 13. So the
    /// dimension cannot be a constant either — it is whatever the observation reports,
    /// and the revision that produced it is stored per row. Prints are only ever compared
    /// within one revision; a row from another is recomputed, not reinterpreted.
    static var featurePrintRevision: Int {
        if #available(macOS 14.0, *) { return VNGenerateImageFeaturePrintRequestRevision2 }
        return VNGenerateImageFeaturePrintRequestRevision1
    }

    /// The seam. Tests swap in a deterministic stub so every ordering, veto, seal and
    /// migration test runs with no Vision involved.
    ///
    /// This matters beyond convenience: Vision is an OS component whose output can change
    /// between macOS releases, so a test asserting exact recognition output would be a
    /// test of the operating system, and would fail on an upgrade that broke nothing we
    /// own. Real Vision is exercised by exactly one smoke test, which asserts containment
    /// and skips when unavailable.
    static var analyze: (Data) -> Result = analyzeWithVision

    /// Restore the real implementation. Tests that swap the seam must call this in
    /// `tearDown`, or they leak a stub into every test that follows.
    static func resetAnalyzer() { analyze = analyzeWithVision }

    /// Takes DECRYPTED image bytes. Pure and free of app state, so it is safe to call
    /// off the main actor — which it must be, since recognition costs 100–300 ms and the
    /// clipboard poll runs every 0.4 s.
    ///
    /// Plaintext exists only inside this call. Both products come from ONE pass over the
    /// same handle: doing them separately would mean decrypting twice and doubling the
    /// window in which the decoded image is in memory.
    static func analyzeWithVision(_ imageData: Data) -> Result {
        let handler = VNImageRequestHandler(data: imageData, options: [:])

        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        // Pinned rather than defaulted, for the same reason as the print revision.
        textRequest.usesLanguageCorrection = true

        let printRequest = VNGenerateImageFeaturePrintRequest()
        printRequest.revision = featurePrintRevision

        // Requests are performed together but their failures are independent: an image
        // Vision cannot read may still yield a usable print, and vice versa. Failing
        // both because one threw would lose information for no benefit.
        try? handler.perform([textRequest, printRequest])

        let lines = (textRequest.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n")

        var vector: [Float] = []
        if let observation = printRequest.results?.first as? VNFeaturePrintObservation,
           observation.elementType == .float,
           observation.elementCount > 0 {
            // Dimension is read from the observation, never assumed: it is 2048 under
            // revision 1 and 768 under revision 2. `Data` is heap-allocated and at least
            // 16-byte aligned, so binding it to Float is safe here.
            vector = observation.data.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: Float.self))
            }
        }

        return Result(text: text,
                      featurePrint: vector,
                      featurePrintRevision: vector.isEmpty ? 0 : featurePrintRevision)
    }

    /// Ordering by cosine descending is equivalent to Vision's own `computeDistance`
    /// ascending, because the print is (very nearly) L2-normalised: for unit vectors
    /// d² = 2 − 2·cos, which is strictly decreasing in cosine.
    ///
    /// "Very nearly" is doing real work in that sentence. Measured norms are 0.9997 and
    /// 1.0006, not exactly 1 — so the two orderings agree in practice but are NOT
    /// identical, and two candidates within ~1e-3 cosine can swap. That is harmless for
    /// a short "similar images" strip and fatal for any test asserting order identity
    /// against `computeDistance`. Do not write that test.
    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        SemanticRanker.cosine(a, b)
    }
}
