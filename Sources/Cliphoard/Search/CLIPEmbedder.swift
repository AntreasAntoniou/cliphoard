import Foundation
import CoreML
import Tokenizers
import CoreImage
import AppKit

/// Joint text-and-pixel embedding: OpenVision-Tiny (patch8/224), Apache-2.0, 17.098M
/// parameters across two towers that share one 192-d space.
///
/// WHY THIS EXISTS, in one measurement. Of the 18 images in the reference store, FIVE hold
/// a sealed EMPTY OCR string — no recognised text at all, mostly photos received through
/// WhatsApp and Messenger — and three more carry 11 characters or fewer. Those clips are
/// reachable today only by scrolling until you see them, because every existing text query
/// path (substring, derived tags, the ogma embedder over OCR output) has nothing to match.
/// 44% of the image corpus is invisible to typing. That gap is what this closes, and it is
/// the ONLY thing this closes: for the text-dense third — terminal captures, ChatGPT
/// transcripts, 2.5-3.8KB of recognised text each — OCR plus ogma already works well, and
/// a CLIP model is expected to be WORSE there. CLIP-family models read rendered text
/// poorly; that is a known weakness, not a tuning problem.
///
/// This is therefore NOT a replacement for the text tiers. `open-ogma-small` and MiniLM
/// keep embedding text into their own space and are untouched. Vectors from the two spaces
/// are never compared: they are stored under different `model` signatures in `embeddings`,
/// which is already keyed by signature precisely so incomparable spaces cannot mix.
///
/// PRE-PROCESSING IS NOT A DETAIL. All three of these were verified against the live
/// upstream config at conversion time, and each is silent if wrong:
///   - normalisation uses IMAGENET stats (.485/.456/.406, .229/.224/.225), NOT CLIP's usual
///     .481/.457/.408. Baked into the CoreML graph, because the per-channel divisor cannot
///     be expressed through `ImageType`'s scalar `scale`.
///   - resize is a SQUASH to 224x224, not shortest-side-then-centre-crop. Lucky for a
///     clipboard: a wide screenshot is distorted rather than having half of it cropped away
///     — and cropping away the half the user searched for is a silent miss, not an error.
///   - the L2 norm is baked in, so cosine is a plain dot product here.
/// The `image` input is an `ImageType`, so CoreML does the 0-255 -> 0-1 scaling itself; the
/// only thing Swift must get right is the geometry, which is why `pixelBuffer` squashes.
final class CLIPEmbedder {

    /// Vectors are only ever comparable within one signature. Bump the trailing version if
    /// the weights, the preprocessing, or the pooling change — a stale vector under a live
    /// signature is indistinguishable from a fresh one, and the failure is a silently wrong
    /// ranking rather than an error.
    static let signature = "openvision-tiny-p8-img-192-v1"
    static let dimension = 192
    static let contextLength = 80
    static let side = 224

    /// Applies to CENTRED scores (see `CLIPTextMean`), which is the only reason a floor can
    /// exist at all here. Raw cosine in this space sits near 0.05 for everything relevant or
    /// not, so any raw threshold is either "everything" or "nothing" — the first version of
    /// this constant was 0.18 against raw scores and would have silently rejected every
    /// result. After centring, scores spread across roughly 0.0-0.25 and a floor separates
    /// signal from noise as intended.
    ///
    /// Still provisional: measured on 30 local images, not on a labelled set. Athena's step
    /// 6 exists to set it properly.
    static let relevanceFloor: Float = 0.08

    /// Remove the space's common direction and renormalise.
    ///
    /// Without this the query is ~98% a constant that every embedding shares, and ranking is
    /// decided by whichever vectors happen to lie nearest that constant — the same images
    /// come back for every query. Returns [] for a degenerate result rather than a zero
    /// vector, matching the rest of this type's contract.
    static func centred(_ v: [Float], by mean: [Float]) -> [Float] {
        guard v.count == mean.count, !v.isEmpty else { return v }
        var out = [Float](repeating: 0, count: v.count)
        var norm: Float = 0
        for i in 0..<v.count {
            out[i] = v[i] - mean[i]
            norm += out[i] * out[i]
        }
        norm = norm.squareRoot()
        guard norm > 1e-6 else { return [] }
        for i in 0..<out.count { out[i] /= norm }
        return out
    }

    private let imageModel: MLModel
    private let textModel: MLModel
    private let tokenizer: Tokenizer

    init(imageModel: MLModel, textModel: MLModel, tokenizer: Tokenizer) {
        self.imageModel = imageModel
        self.textModel = textModel
        self.tokenizer = tokenizer
    }

    // MARK: - Loading

    /// Both towers plus the shared tokenizer, or nil. ALL-OR-NOTHING on purpose: a
    /// half-installed pair is a live failure mode in which image→image quietly works while
    /// every text query returns nothing, with no error anywhere.
    static func load() -> CLIPEmbedder? {
        guard let imageURL = locate("openvision-tiny-p8-image"),
              let textURL = locate("openvision-tiny-p8-text"),
              let tokURL = locateFolder("openvision-tiny-p8-text-tokenizer") else {
            return nil
        }
        do {
            let config = MLModelConfiguration()
            // `.all` lets CoreML use the Neural Engine. Shapes are fixed (224x224 pixels,
            // exactly 80 tokens) specifically so it can: dynamic sequence length is the
            // usual cause of an ANE→CPU fallback that shows up only as latency.
            config.computeUnits = .all
            let image = try MLModel(contentsOf: imageURL, configuration: config)
            let text = try MLModel(contentsOf: textURL, configuration: config)
            let tok = try loadTokenizer(from: tokURL)
            return CLIPEmbedder(imageModel: image, textModel: text, tokenizer: tok)
        } catch {
            NSLog("Cliphoard CLIPEmbedder: load failed: \(error)")
            return nil
        }
    }

    private static func loadTokenizer(from folder: URL) throws -> Tokenizer {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Tokenizer, Error>!
        Task.detached {
            do { result = .success(try await AutoTokenizer.from(modelFolder: folder)) }
            catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }

    private static func locate(_ name: String) -> URL? {
        if let bundled = Bundle.main.url(forResource: name, withExtension: "mlmodelc") {
            return bundled
        }
        let stored = ModelAssets.storeDir.appendingPathComponent("\(name).mlmodelc")
        return FileManager.default.fileExists(atPath: stored.path) ? stored : nil
    }

    private static func locateFolder(_ name: String) -> URL? {
        if let bundled = Bundle.main.url(forResource: name, withExtension: nil),
           FileManager.default.fileExists(
                atPath: bundled.appendingPathComponent("tokenizer.json").path) {
            return bundled
        }
        let stored = ModelAssets.storeDir.appendingPathComponent(name)
        return FileManager.default.fileExists(
            atPath: stored.appendingPathComponent("tokenizer.json").path) ? stored : nil
    }

    // MARK: - Text → 192-d

    /// A free-text query in the joint space. `[]` on any failure, never zeros: a zero vector
    /// would be cached as a valid embedding and never retried, and would score 0 against
    /// everything — indistinguishable from "nothing matched".
    func embed(text: String) -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var ids = tokenizer.encode(text: trimmed).map { Int32($0) }
        // FIXED length 80, padded with 0 and truncated keeping the final special token.
        // The graph was converted with a fixed shape, so this is not merely conventional —
        // a different length is a prediction error, not a slower path.
        if ids.count > Self.contextLength {
            ids = Array(ids.prefix(Self.contextLength - 1)) + [ids[ids.count - 1]]
        }
        let padded = ids + [Int32](repeating: 0, count: Self.contextLength - ids.count)

        guard let arr = try? MLMultiArray(shape: [1, NSNumber(value: Self.contextLength)],
                                          dataType: .int32) else { return [] }
        for i in 0..<Self.contextLength { arr[i] = NSNumber(value: padded[i]) }

        do {
            let input = try MLDictionaryFeatureProvider(dictionary: ["input_ids": arr])
            return Self.vector(from: try textModel.prediction(from: input))
        } catch {
            NSLog("Cliphoard CLIPEmbedder: text prediction failed: \(error)")
            return []
        }
    }

    // MARK: - Pixels → 192-d

    /// Takes DECRYPTED image bytes, like `ImageUnderstanding.analyze`. Pure and free of app
    /// state, so it is safe off the main actor — which it must be: this runs over the whole
    /// image corpus during backfill.
    func embed(imageData: Data) -> [Float] {
        guard let buffer = Self.pixelBuffer(from: imageData) else { return [] }
        do {
            let input = try MLDictionaryFeatureProvider(dictionary: ["image": buffer])
            return Self.vector(from: try imageModel.prediction(from: input))
        } catch {
            NSLog("Cliphoard CLIPEmbedder: image prediction failed: \(error)")
            return []
        }
    }

    /// SQUASH to 224x224 — both dimensions forced, aspect ratio deliberately not preserved,
    /// matching `Resize(size=(224,224))` in the model's own preprocessing. Drawing into a
    /// full-size rect is what performs the squash; an aspect-fit here would letterbox and an
    /// aspect-fill would crop, and both would put the model off its training distribution
    /// in a way that produces a plausible vector rather than an error.
    static func pixelBuffer(from data: Data) -> CVPixelBuffer? {
        guard let source = NSBitmapImageRep(data: data)?.cgImage
                ?? NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, side, side,
                                  kCVPixelFormatType_32BGRA, attrs as CFDictionary,
                                  &buffer) == kCVReturnSuccess,
              let pixels = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixels),
            width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }

        context.interpolationQuality = .default    // bilinear, matching the reference resize
        context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
        return pixels
    }

    private static func vector(from output: MLFeatureProvider) -> [Float] {
        guard let emb = output.featureValue(for: "embedding")?.multiArrayValue else {
            NSLog("Cliphoard CLIPEmbedder: no 'embedding' output; features=\(output.featureNames)")
            return []
        }
        var v = [Float](repeating: 0, count: emb.count)
        for i in 0..<emb.count { v[i] = emb[i].floatValue }
        return v
    }

    /// Cosine for L2-normalised vectors — a dot product. Refuses mismatched dimensions
    /// rather than comparing a prefix, because a vector from another space or another
    /// revision must score nothing, not something plausible.
    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var total: Float = 0
        for i in 0..<a.count { total += a[i] * b[i] }
        return total
    }
}
