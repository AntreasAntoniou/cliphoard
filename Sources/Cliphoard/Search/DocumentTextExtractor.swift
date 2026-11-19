import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Bounded, local parsing. No network, execution, archive traversal or OCR. A scan-only
/// PDF has no embedded text and is reported as empty rather than silently running OCR.
enum DocumentTextExtractor {
    static let maximumBytes = 16 * 1024 * 1024
    static let maximumCharacters = 200_000
    static let maximumPages = 100
    enum Failure: Error { case unsupported, unavailable, tooLarge, changed, encrypted, invalidText }
    struct Stamp: Equatable {
        let bytes: Int
        let modified: Date
        let inode: UInt64
    }
    struct Result { let text: String; let truncated: Bool; let stamp: Stamp }
    static func stamp(_ url: URL, maximumBytes: Int = maximumBytes) throws -> Stamp {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL else { throw Failure.unavailable }
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        guard a[.type] as? FileAttributeType == .typeRegular,
              let bytes = a[.size] as? NSNumber, let date = a[.modificationDate] as? Date,
              let inode = a[.systemFileNumber] as? NSNumber else { throw Failure.unavailable }
        guard bytes.intValue <= maximumBytes else { throw Failure.tooLarge }
        return Stamp(bytes: bytes.intValue, modified: date, inode: inode.uint64Value)
    }
    static func supports(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["pdf", "rtf", "txt", "md", "csv", "tsv", "json", "xml", "html", "htm", "log", "yaml", "yml", "swift", "py", "rs", "js", "ts", "css", "sh"].contains(ext)
            || UTType(filenameExtension: ext)?.conforms(to: .plainText) == true
    }
    static func extract(_ url: URL, pdf: Bool = true, richText: Bool = true) throws -> Result {
        guard supports(url) else { throw Failure.unsupported }
        let before = try stamp(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        var text = "", truncated = false
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard pdf else { throw Failure.unsupported }
            guard let document = PDFDocument(data: data), !document.isLocked else { throw Failure.encrypted }
            truncated = document.pageCount > maximumPages
            for page in 0..<min(document.pageCount, maximumPages) {
                try Task.checkCancellation()
                text += (document.page(at: page)?.string ?? "") + "\n"
                if text.count > maximumCharacters { truncated = true; break }
            }
        case "rtf":
            guard richText else { throw Failure.unsupported }
            guard let value = NSAttributedString(rtf: data, documentAttributes: nil) else { throw Failure.invalidText }
            text = value.string
        default:
            // HTML is searched as source text; never use WebKit or an HTML importer,
            // which could fetch remote resources embedded in a copied document.
            let utf16BOM = data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff])
            guard let value = String(data: data, encoding: utf16BOM ? .utf16 : .utf8),
                  !value.contains("\0") else { throw Failure.invalidText }
            text = value
        }
        guard try stamp(url) == before else { throw Failure.changed }
        truncated = truncated || text.count > maximumCharacters
        return Result(text: String(text.prefix(maximumCharacters)), truncated: truncated, stamp: before)
    }
}
