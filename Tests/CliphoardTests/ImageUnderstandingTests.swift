import XCTest
import CoreGraphics
import Vision
@testable import Cliphoard

/// TP-16: the recognition seam.
///
/// Almost everything here runs through the injectable `analyze` seam with no Vision
/// involved. That is deliberate, not laziness: Vision is an operating-system component
/// whose output can change between macOS releases, so a test asserting exact recognition
/// output would be testing the OS and would go red on an upgrade that broke nothing this
/// project owns. Exactly one test below touches real Vision, asserts CONTAINMENT rather
/// than equality, and skips rather than fails when the framework cannot deliver.
final class ImageUnderstandingTests: XCTestCase {

    override func tearDown() {
        // A leaked stub would silently rewrite every later test's idea of reality.
        ImageUnderstanding.resetAnalyzer()
        super.tearDown()
    }

    // MARK: - The seam

    func testAnalyzerIsSwappableAndRestorable() {
        let sentinel = ImageUnderstanding.Result(
            text: "stubbed", featurePrint: [1, 0, 0], featurePrintRevision: 99)
        ImageUnderstanding.analyze = { _ in sentinel }
        XCTAssertEqual(ImageUnderstanding.analyze(Data()), sentinel)

        ImageUnderstanding.resetAnalyzer()
        // The real analyzer on empty bytes must not crash and must yield nothing usable.
        let real = ImageUnderstanding.analyze(Data())
        XCTAssertEqual(real.text, "", "empty data cannot produce recognised text")
        XCTAssertTrue(real.featurePrint.isEmpty, "empty data cannot produce a print")
        XCTAssertEqual(real.featurePrintRevision, 0,
                       "a failed print must record revision 0, not a revision it never ran")
    }

    /// Garbage bytes are the realistic failure: a truncated or non-image payload. It must
    /// degrade to "nothing found", never trap.
    func testNonImageBytesDegradeQuietly() {
        let junk = Data((0..<512).map { _ in UInt8.random(in: 0...255) })
        let result = ImageUnderstanding.analyze(junk)
        XCTAssertEqual(result.text, "")
        XCTAssertTrue(result.featurePrint.isEmpty)
    }

    // MARK: - Revision pinning

    /// The request defaults to the newest revision available. Accepting that default is
    /// how a future macOS silently starts producing vectors in a different space and
    /// comparing them against stored ones — no error, just a similarity feature that
    /// stops working. This asserts we pin, and pin to something real.
    func testFeaturePrintRevisionIsPinnedToASupportedRevision() {
        let pinned = ImageUnderstanding.featurePrintRevision
        XCTAssertGreaterThan(pinned, 0, "revision must be pinned, not left at a default of 0")

        let supported = VNGenerateImageFeaturePrintRequest.supportedRevisions
        XCTAssertTrue(supported.contains(pinned),
                      "pinned revision \(pinned) is not among this OS's supported "
                      + "revisions \(supported) — the pin has drifted past the platform")

        if #available(macOS 14.0, *) {
            XCTAssertEqual(pinned, VNGenerateImageFeaturePrintRequestRevision2,
                           "on macOS 14+ we should pin revision 2 (768-d), not fall back")
        } else {
            XCTAssertEqual(pinned, VNGenerateImageFeaturePrintRequestRevision1,
                           "on macOS 13 revision 2 does not exist; revision 1 (2048-d) is correct")
        }
    }

    /// Dimension must never be hardcoded: revision 1 emits 2048 floats and revision 2
    /// emits 768. A constant would be wrong on one of the two OSes this package supports.
    func testResultCarriesTheRevisionThatProducedThePrint() {
        let stub = ImageUnderstanding.Result(
            text: "", featurePrint: [Float](repeating: 0.5, count: 2048), featurePrintRevision: 1)
        XCTAssertEqual(stub.featurePrint.count, 2048)
        XCTAssertEqual(stub.featurePrintRevision, 1,
                       "a stored print is only comparable within its own revision, so the "
                       + "revision travels with the vector")
    }

    // MARK: - Similarity ordering

    /// Ranking by cosine descending matches Vision's own distance ascending, because the
    /// print is L2-normalised: for unit vectors d² = 2 − 2·cos.
    ///
    /// Note what is NOT asserted: identity with `computeDistance`. Measured norms are
    /// 0.9997/1.0006, not exactly 1, so the orderings agree in practice but can differ
    /// for candidates within ~1e-3. Asserting identity would be asserting something false.
    func testCosineOrderingMatchesEuclideanOrderingOnUnitVectors() {
        func unit(_ v: [Float]) -> [Float] {
            let n = (v.reduce(0) { $0 + $1 * $1 }).squareRoot()
            return v.map { $0 / n }
        }
        let query = unit([1, 0, 0, 0])
        let near   = unit([0.9, 0.1, 0, 0])
        let middle = unit([0.5, 0.5, 0.5, 0])
        let far    = unit([0, 0, 0, 1])

        let byCosine = [near, middle, far]
            .map { ImageUnderstanding.similarity(query, $0) }
        XCTAssertTrue(byCosine[0] > byCosine[1] && byCosine[1] > byCosine[2],
                      "cosine must order near > middle > far, got \(byCosine)")

        func euclidean(_ a: [Float], _ b: [Float]) -> Float {
            zip(a, b).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }.squareRoot()
        }
        let byDistance = [near, middle, far].map { euclidean(query, $0) }
        XCTAssertTrue(byDistance[0] < byDistance[1] && byDistance[1] < byDistance[2],
                      "Euclidean must order the same way, inverted: \(byDistance)")
    }

    func testSimilarityOfMismatchedLengthsIsZeroNotACrash() {
        XCTAssertEqual(ImageUnderstanding.similarity([1, 0, 0], [1, 0]), 0,
                       "a revision-1 print compared against a revision-2 one must score 0, "
                       + "not trap and not accidentally rank")
    }

    // MARK: - The one real-Vision test

    /// Renders text with CoreGraphics — NOT `NSImage.lockFocus`, which needs a window
    /// server and would make this untestable headlessly. Asserts CONTAINMENT: exact
    /// equality would be a test of Apple's recognizer, not of this code.
    func testRealVisionReadsRenderedText() throws {
        let needle = "AKIAIOSFODNN7EXAMPLE"
        guard let png = Self.renderPNG(text: needle) else {
            throw XCTSkip("could not render a fixture image without a window server")
        }
        let result = ImageUnderstanding.analyzeWithVision(png)
        guard !result.text.isEmpty || !result.featurePrint.isEmpty else {
            throw XCTSkip("Vision returned nothing — unavailable in this environment")
        }

        XCTAssertTrue(result.text.contains(needle),
                      "Vision read \"\(result.text)\" and did not contain the fixture. "
                      + "This is the load-bearing fact behind the withhold rule: a "
                      + "screenshot of a credential IS recoverable as text.")
        XCTAssertFalse(result.featurePrint.isEmpty, "a real image must yield a print")
        XCTAssertEqual(result.featurePrintRevision, ImageUnderstanding.featurePrintRevision)

        let norm = (result.featurePrint.reduce(0) { $0 + $1 * $1 }).squareRoot()
        XCTAssertEqual(norm, 1, accuracy: 0.01,
                       "the print must be ~L2-normalised, which is what makes cosine "
                       + "ordering agree with Vision's own distance")
    }

    /// CoreGraphics-only text rendering: a white bitmap with black text, no AppKit views.
    private static func renderPNG(text: String) -> Data? {
        let width = 900, height = 200
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica" as CFString, 54, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        ctx.textPosition = CGPoint(x: 30, y: 80)
        CTLineDraw(line, ctx)

        guard let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
