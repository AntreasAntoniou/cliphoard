import XCTest
import AppKit
import PDFKit
@testable import Cliphoard

@MainActor
final class ContentAnalysisTests: XCTestCase {
    private let keys = ["nsfwEnabled", "nsfwFocusOnly", "documentTextEnabled", "documentPDFEnabled", "documentRichTextEnabled", "documentTagsEnabled"]
    private var saved: [String: Any] = [:]
    override func setUp() {
        super.setUp()
        for key in keys {
            saved[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        FocusProtectionState.set(nil)
    }
    override func tearDown() {
        for key in keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        FocusProtectionState.set(nil)
        super.tearDown()
    }
    func testNSFWIsEnabledByDefaultAndFocusTransitionsDoNotUseCachedSensitivity() {
        let item = ClipItem(kind: .text, text: "ordinary sample")
        item.flags = [.nsfw]
        XCTAssertTrue(SensitiveClipPolicy.requiresAuthentication(item))
        UserDefaults.standard.set(false, forKey: "nsfwEnabled")
        XCTAssertFalse(SensitiveClipPolicy.requiresAuthentication(item))
        item.flags.insert(.secret)
        XCTAssertTrue(SensitiveClipPolicy.requiresAuthentication(item), "NSFW opt-out cannot disable credentials")
        item.flags = [.nsfw]
        UserDefaults.standard.set(true, forKey: "nsfwEnabled")
        UserDefaults.standard.set(true, forKey: "nsfwFocusOnly")
        FocusProtectionState.set(false)
        XCTAssertFalse(SensitiveClipPolicy.requiresAuthentication(item))
        FocusProtectionState.set(true)
        XCTAssertTrue(SensitiveClipPolicy.requiresAuthentication(item))
        FocusProtectionState.set(nil)
        XCTAssertTrue(SensitiveClipPolicy.requiresAuthentication(item), "Unknown Focus is not permission to expose content")
    }
    func testFreePathsAndManualOverride() {
        let item = ClipItem(kind: .file, text: "movie")
        item.filePath = "/tmp/nsfw/movie.mp4"
        XCTAssertTrue(SensitiveClipPolicy.requiresAuthentication(item))
        XCTAssertFalse(NSFWDetection.permitsMedia(isVideoOrAudio: true, isPro: false, active: true))
        XCTAssertTrue(NSFWDetection.permitsMedia(isVideoOrAudio: false, isPro: false, active: true))
        XCTAssertTrue(NSFWDetection.permitsMedia(isVideoOrAudio: true, isPro: true, active: true))
        XCTAssertFalse(NSFWDetection.permitsMedia(isVideoOrAudio: true, isPro: true, active: false))
        item.userTags = ["nsfw-exempt"]
        XCTAssertFalse(SensitiveClipPolicy.requiresAuthentication(item))
        item.flags = [.secret]
        XCTAssertTrue(SensitiveClipPolicy.requiresAuthentication(item))
        XCTAssertFalse(NSFWDetection.explicitLabel("Essex medical anatomy notes"))
        XCTAssertTrue(NSFWDetection.explicitLabel("/tmp/%6Esfw/movie.mov"))
    }
    func testCoreProtectionCannotBeBypassedByNSFWExemption() {
        let item = ClipItem(kind: .text, text: "ordinary text")
        item.flags = [.nsfw]
        XCTAssertFalse(SensitiveClipPolicy.requiresCoreAuthentication(item))
        item.flags.insert(.secret)
        item.userTags = ["nsfw-exempt"]
        XCTAssertTrue(SensitiveClipPolicy.requiresCoreAuthentication(item))
        item.flags = []
        item.rtf = Data("rich content".utf8)
        XCTAssertTrue(SensitiveClipPolicy.requiresCoreAuthentication(item))
    }
    func testNSFWBitRoundTripsWithoutRenumberingExistingBits() throws {
        XCTAssertEqual(ClipFlags.nsfw.rawValue, 128)
        XCTAssertEqual(ClipFlags.quarantined.rawValue, 64)
        let flags: ClipFlags = [.nsfw, .financial, ClipFlags(rawValue: 1 << 24)]
        XCTAssertEqual(try JSONDecoder().decode(ClipFlags.self, from: JSONEncoder().encode(flags)), flags)
    }
    func testSemanticDecisionRequiresFiniteCompatibleVectorsAndContrast() {
        XCTAssertTrue(NSFWDetection.possibleMatch(vector: [1, 0], positive: [[1, 0]], negative: [[0, 1]]))
        XCTAssertFalse(NSFWDetection.possibleMatch(vector: [0, 1], positive: [[1, 0]], negative: [[0, 1]]))
        XCTAssertFalse(NSFWDetection.possibleMatch(vector: [1, 0], positive: [[1, 0]], negative: [[1, 0]]))
        XCTAssertFalse(NSFWDetection.possibleMatch(vector: [Float.nan, 0], positive: [[1, 0]], negative: [[0, 1]]))
        XCTAssertFalse(NSFWDetection.possibleMatch(vector: [1], positive: [[1, 0]], negative: [[0, 1]]))
    }
    func testTextExtractionSearchOptOutAndLimits() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notes.txt")
        try Data("Nebula lattice research notes".utf8).write(to: file)
        let result = try DocumentTextExtractor.extract(file)
        XCTAssertEqual(result.text, "Nebula lattice research notes")
        let item = ClipItem(kind: .file, text: "notes.txt")
        item.filePath = file.path; item.ocrText = result.text
        XCTAssertEqual(SemanticRanker.searchText(item), "notes.txt")
        UserDefaults.standard.set(true, forKey: "documentTextEnabled")
        XCTAssertTrue(SemanticRanker.searchText(item).contains("Nebula lattice"))
        UserDefaults.standard.set(false, forKey: "documentTextEnabled")
        XCTAssertFalse(SemanticRanker.searchText(item).contains("Nebula lattice"))
        try Data(repeating: 65, count: DocumentTextExtractor.maximumCharacters + 12).write(to: file)
        let clipped = try DocumentTextExtractor.extract(file)
        XCTAssertTrue(clipped.truncated)
        XCTAssertEqual(clipped.text.count, DocumentTextExtractor.maximumCharacters)
        let link = dir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try DocumentTextExtractor.extract(link))
        let binary = dir.appendingPathComponent("bad.txt")
        try Data([0, 0, 0, 0]).write(to: binary)
        XCTAssertThrowsError(try DocumentTextExtractor.extract(binary))
        XCTAssertFalse(DocumentTextExtractor.supports(dir.appendingPathComponent("video.mov")))
    }
    func testStoredFileTextIsSearchableOnlyWhenEnabledAndSecretsAreWithheld() throws {
        try skipIfKeychainUnreachable()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("document-search-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipStore(directory: dir)
        let item = ClipItem(kind: .file, text: "notes.txt")
        item.filePath = "/tmp/notes.txt"
        store.add(item)
        UserDefaults.standard.set(true, forKey: "documentTextEnabled")
        store.applyDocumentText("Nebula lattice research notes", to: item)
        XCTAssertEqual(store.filtered(kind: nil, query: "nebula lattice", pinnedOnly: false).map(\.id), [item.id])
        UserDefaults.standard.set(false, forKey: "documentTextEnabled")
        XCTAssertTrue(store.filtered(kind: nil, query: "nebula lattice", pinnedOnly: false).isEmpty)
        XCTAssertTrue(store.tags(of: item).isEmpty)
        XCTAssertEqual(item.ocrText, "Nebula lattice research notes", "Disabling indexing retains the inspectable snapshot")
        UserDefaults.standard.set(true, forKey: "documentTextEnabled")
        store.applyDocumentText("AKIAIOSFODNN7EXAMPLE", to: item)
        XCTAssertTrue(item.flags.contains(.secret))
        XCTAssertEqual(item.ocrText, "")
        XCTAssertTrue(store.filtered(kind: nil, query: "AKIAIOSFODNN7EXAMPLE", pinnedOnly: false).isEmpty)
    }
    func testRichTextAndPDFExtraction() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rtf = dir.appendingPathComponent("note.rtf")
        try Data(#"{\rtf1\ansi Synthetic document text}"#.utf8).write(to: rtf)
        XCTAssertTrue(try DocumentTextExtractor.extract(rtf).text.contains("Synthetic document text"))
        XCTAssertThrowsError(try DocumentTextExtractor.extract(rtf, richText: false))
        let pdf = dir.appendingPathComponent("note.pdf")
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSAttributedString(string: "Synthetic PDF nebula", attributes: [.font: NSFont.systemFont(ofSize: 14)]).draw(at: NSPoint(x: 20, y: 100))
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage(); context.closePDF()
        try (data as Data).write(to: pdf)
        XCTAssertTrue(try DocumentTextExtractor.extract(pdf).text.contains("Synthetic PDF nebula"))
        XCTAssertThrowsError(try DocumentTextExtractor.extract(pdf, pdf: false))
    }
}
