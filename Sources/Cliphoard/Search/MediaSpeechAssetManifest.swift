import Foundation
import CryptoKit

/// Independent immutable public repository metadata, not a receipt minted from cache bytes.
enum MediaSpeechAssetManifest {
    enum Failure: Error, Equatable { case invalidManifest, unsafePath, missing, corrupt, downloadRefused, deadline }
    struct Entry: Sendable {
        let repository: String
        let revision: String
        let path: String
        let bytes: Int64
        let algorithm: String
        let digest: String
        var relativePath: String { "models/\(repository)/\(path)" }
        var url: URL { URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(path)")! }
    }
    static let modelRevision = "0f63a7800b00dd0226abd051b906c246e1907482"
    static let smallRevision = "973afd24965f72e36ca33b3055d56a652f456b4d"
    static let largeRevision = "06f233fe06e710322aca913c1bc4249a0d71fce1"

    static func entries(for model: MediaSpeechModel) -> [Entry] {
        switch model {
        case .small: return smallModel + smallTokenizer
        case .largeV3: return largeModel + largeTokenizer
        case .turbo: return turboModel + largeTokenizer
        }
    }
    static func totalBytes(for model: MediaSpeechModel) -> Int64 { entries(for: model).reduce(0) { $0 + $1.bytes } }
    static func directory(for model: MediaSpeechModel, in root: URL) -> URL {
        root.appendingPathComponent("\(modelRevision)-\(model == .small ? smallRevision : largeRevision)", isDirectory: true)
    }
    static func check(_ deadline: Double) throws {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.deadline }
    }
    static func safePath(_ url: URL) throws {
        guard url.isFileURL, [nil, "", "localhost"].contains(url.host),
              url.path.hasPrefix("/"),
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        else { throw Failure.unsafePath }
        // Preserve physical /private/var paths; standardization can rewrite them through /var's symlink.
        var current = url
        while true {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: current.path),
               attrs[.type] as? FileAttributeType == .typeSymbolicLink { throw Failure.unsafePath }
            let parent = current.deletingLastPathComponent()
            if parent == current { break }; current = parent
        }
    }
    static func validate(_ entry: Entry) throws {
        let pieces = entry.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              entry.bytes > 0, entry.bytes <= 8_000_000_000,
              ["sha256","git-sha1"].contains(entry.algorithm),
              entry.digest.count == (entry.algorithm == "sha256" ? 64 : 40),
              entry.digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw Failure.invalidManifest }
    }
    static func verifyFile(_ file: URL, entry: Entry, deadline: Double) throws {
        try validate(entry); try safePath(file); try check(deadline)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path) else { throw Failure.missing }
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.size] as? NSNumber)?.int64Value == entry.bytes else { throw Failure.corrupt }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var sha = SHA256(); var git = Insecure.SHA1()
        git.update(data: Data("blob \(entry.bytes)\0".utf8))
        var count: Int64 = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try check(deadline); count += Int64(chunk.count)
            guard count <= entry.bytes else { throw Failure.corrupt }
            if entry.algorithm == "sha256" { sha.update(data: chunk) } else { git.update(data: chunk) }
        }
        let actual = entry.algorithm == "sha256"
            ? sha.finalize().map { String(format: "%02x", $0) }.joined()
            : git.finalize().map { String(format: "%02x", $0) }.joined()
        guard count == entry.bytes, actual == entry.digest else { throw Failure.corrupt }
    }
    /// Reject extra loadable model files too; optional CoreML components cannot bypass pins.
    static func checkInventory(_ entries: [Entry], root: URL) throws {
        try safePath(root)
        for entry in entries { try validate(entry) }
        let expected = Set(entries.map(\.relativePath))
        guard expected.count == entries.count else { throw Failure.invalidManifest }
        let groups = Set(entries.map { entry in
            "models/" + entry.repository + (entry.repository == "argmaxinc/whisperkit-coreml" ? "/" + String(entry.path.split(separator: "/")[0]) : "")
        })
        for group in groups {
            let folder = root.appendingPathComponent(group); try safePath(folder)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            guard let paths = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey,.isDirectoryKey,.isSymbolicLinkKey]) else { throw Failure.corrupt }
            for case let path as URL in paths {
                let info = try path.resourceValues(forKeys: [.isRegularFileKey,.isDirectoryKey,.isSymbolicLinkKey])
                guard info.isSymbolicLink != true else { throw Failure.unsafePath }
                if info.isDirectory == true { continue }
                guard info.isRegularFile == true, expected.contains(String(path.path.dropFirst(root.path.count + 1))) else { throw Failure.corrupt }
            }
        }
    }
    static func prepare(model: MediaSpeechModel, root: URL, allowDownload: Bool,
                        progress: @escaping @Sendable (Int64, Int64) -> Void = { _,_ in }) async throws -> URL {
        let deadline = ProcessInfo.processInfo.systemUptime + 1800
        let assets = entries(for: model), directory = directory(for: model, in: root)
        try checkInventory(assets, root: directory)
        var missing: [Entry] = []; var verified: Int64 = 0
        let total = totalBytes(for: model)
        // Validate every present file before ANY network or mutation. Bad cache stays untouched.
        for entry in assets {
            let file = directory.appendingPathComponent(entry.relativePath)
            if FileManager.default.fileExists(atPath: file.path) {
                try verifyFile(file, entry: entry, deadline: deadline); verified += entry.bytes
            } else { missing.append(entry) }
        }
        progress(verified,total)
        guard missing.isEmpty || allowDownload else { throw Failure.missing }
        if missing.isEmpty { return directory }
        for entry in missing {
            try check(deadline)
            let target = directory.appendingPathComponent(entry.relativePath)
            try safePath(target)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let staging = directory.appendingPathComponent(".speech-download-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staging) }
            let completed = verified
            let transfer = SpeechAssetTransfer(destination: staging, expectedBytes: entry.bytes, deadline: deadline,
                                               progress: { progress(completed + $0, total) })
            try await transfer.start(entry.url)
            try verifyFile(staging, entry: entry, deadline: deadline)
            try safePath(target); try check(deadline)
            // moveItem refuses any concurrently appeared destination; no replacement/reblessing.
            try FileManager.default.moveItem(at: staging, to: target)
            verified += entry.bytes; progress(verified,total)
        }
        try checkInventory(assets, root: directory)
        for entry in assets { try verifyFile(directory.appendingPathComponent(entry.relativePath), entry: entry, deadline: deadline) }
        return directory
    }
    // Immutable expected entries generated from bounded public metadata at the exact revisions.
    // LFS files use their content SHA256; ordinary Git files include the Git blob header in SHA1.
    private static let smallModel: [Entry] = [
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-small/AudioEncoder.mlmodelc/analytics/coremldata.bin", bytes: 243, algorithm: "sha256", digest: "211457b92a0ced67bb8625efe39799a0030c4fc71eb87d7284ea81043caccde7"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-small/AudioEncoder.mlmodelc/coremldata.bin", bytes: 347, algorithm: "sha256", digest: "d68f152b6573ac55203a3dc8383730e6ecde685c7d2a88815b89820c88e35371"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-small/AudioEncoder.mlmodelc/metadata.json", bytes: 1868, algorithm: "git-sha1", digest: "9f06d3ae86653eca79c3b7b8fbde3379d72185ee"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-small/AudioEncoder.mlmodelc/model.mil", bytes: 1636668, algorithm: "git-sha1", digest: "0dd59f0859f9a655599067124f0583a5263a0be5"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-small/AudioEncoder.mlmodelc/model.mlmodel", bytes: 155271, algorithm: "sha256", digest: "68ca04660b8b050c68ca54c27d97c47e4133bc591422cb7009de8922d56fb8c9"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-small/AudioEncoder.mlmodelc/weights/weight.bin", bytes: 176323456, algorithm: "sha256", digest: "fe35cef2c9406993a635639b16f373f6debb0215ac115b7bf93fa03c8e10310b"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-small/MelSpectrogram.mlmodelc/analytics/coremldata.bin", bytes: 243, algorithm: "sha256", digest: "7f77e6457285248f99cd7aa3fd4cc2efbb17733e63e7023ac53abe1f95785d07"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-small/MelSpectrogram.mlmodelc/coremldata.bin", bytes: 328, algorithm: "sha256", digest: "dabdc5aa69f6ef4d97dc9499f5c30514e00e96b53b750b33a5a6471363c71662"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-small/MelSpectrogram.mlmodelc/metadata.json", bytes: 1848, algorithm: "git-sha1", digest: "022c382ec7041de63c59dd98893c3134d01b23aa"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-small/MelSpectrogram.mlmodelc/model.mil", bytes: 10176, algorithm: "git-sha1", digest: "a63d7fa99d6d86db1b76a1f53640cb4aa25e0210"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-small/MelSpectrogram.mlmodelc/weights/weight.bin", bytes: 354080, algorithm: "sha256", digest: "267017e533b5f542d195fd9a775f2ba649075128283ce8e86c63a2ec20de5b07"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-small/TextDecoder.mlmodelc/analytics/coremldata.bin", bytes: 243, algorithm: "sha256", digest: "39c0d6d55353bc61ef8071081bb958dd1ab7b0b7f2a3338a797f1a64211e084c"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-small/TextDecoder.mlmodelc/coremldata.bin", bytes: 633, algorithm: "sha256", digest: "b2ccd0b8920701386ab9554f7db47b43e55ee07863280ee5d829d5272839adc2"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-small/TextDecoder.mlmodelc/metadata.json", bytes: 4757, algorithm: "git-sha1", digest: "6cdc64a42b740095de45e0b4e49e261bea73558a"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-small/TextDecoder.mlmodelc/model.mil", bytes: 392094, algorithm: "git-sha1", digest: "dca5e408299638f61530c44b7ed4442b8e3b646b"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-small/TextDecoder.mlmodelc/model.mlmodel", bytes: 313629, algorithm: "sha256", digest: "7ea861c6dfdd866ed0f2e7fe0c3df7459daa44481cb25236e03698dd6d259391"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-small/TextDecoder.mlmodelc/weights/weight.bin", bytes: 307287346, algorithm: "sha256", digest: "bfea8044a8f38e8d33f56585b1e75ce023d3845e2a945e20480bd7e16558016e"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-small/config.json", bytes: 1456, algorithm: "git-sha1", digest: "9dee569cf0c20925208ec84fecbb95e873f8bf24"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-small/generation_config.json", bytes: 2779, algorithm: "git-sha1", digest: "cdd26273f9cd1ab8ecda49f5b8c033134c61cb4a"),
    ]
    private static let smallTokenizer: [Entry] = [
        Entry(repository: "openai/whisper-small", revision: "973afd24965f72e36ca33b3055d56a652f456b4d", path: "config.json", bytes: 1967, algorithm: "git-sha1", digest: "113bb3efe3a7396f2ea629eef12637bd8085238d"),
        Entry(repository: "openai/whisper-small", revision: "973afd24965f72e36ca33b3055d56a652f456b4d", path: "tokenizer.json", bytes: 2480466, algorithm: "git-sha1", digest: "1e95340ff836fad1b5932e800fb7b8c5e6d78a74"),
        Entry(repository: "openai/whisper-small", revision: "973afd24965f72e36ca33b3055d56a652f456b4d", path: "tokenizer_config.json", bytes: 282683, algorithm: "git-sha1", digest: "d13b786c04765fb1a06492b53587752cd67665ea"),
    ]
    private static let largeModel: [Entry] = [
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3/AudioEncoder.mlmodelc/analytics/coremldata.bin", bytes: 243, algorithm: "sha256", digest: "195e35e9fbaa218cd59eca69988a2165245e5bfccc4a5d9776847e8955d1625a"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3/AudioEncoder.mlmodelc/coremldata.bin", bytes: 348, algorithm: "sha256", digest: "273d6cd004f95763e9d03e5d36622f11038819a81b9eafed64b1d95444e04f62"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3/AudioEncoder.mlmodelc/metadata.json", bytes: 1826, algorithm: "git-sha1", digest: "a88c71ad25165a42deae27ce1ca3f4dbf959a42d"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3/AudioEncoder.mlmodelc/model.mil", bytes: 581035, algorithm: "git-sha1", digest: "5363d866897458fa13ffa4e9a4e8726b57e2bc61"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3/AudioEncoder.mlmodelc/model.mlmodel", bytes: 408667, algorithm: "sha256", digest: "bf0987c0d8c3fe180877b12ba5b4ac1d890e011f2103926e53186089feced575"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3/AudioEncoder.mlmodelc/weights/weight.bin", bytes: 1273974400, algorithm: "sha256", digest: "eb07bab32dcd62ce653b5b288bd6c27bdc5a538be309f242e33ed05e1cb53457"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3/MelSpectrogram.mlmodelc/analytics/coremldata.bin", bytes: 243, algorithm: "sha256", digest: "091a361134891f94e613562771beea0d93a9aefbc6984ba86c60f856e07a508f"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3/MelSpectrogram.mlmodelc/coremldata.bin", bytes: 329, algorithm: "sha256", digest: "f3c5778c86d6fbc6a9817a56dbcac05a946a4d95c77f6db8355572f3be9e9a68"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3/MelSpectrogram.mlmodelc/metadata.json", bytes: 1850, algorithm: "git-sha1", digest: "50aa9006cb42b48fc44dcfa3c74c4751ea16e695"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3/MelSpectrogram.mlmodelc/model.mil", bytes: 10187, algorithm: "git-sha1", digest: "4cbec89bb76fb8a5edf95927d3a888989f287ff4"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3/MelSpectrogram.mlmodelc/weights/weight.bin", bytes: 373376, algorithm: "sha256", digest: "97a66b915cd3fc97dcba6806d92381e1a56024b8f68c1a1cd370d4c92505fe87"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3/TextDecoder.mlmodelc/analytics/coremldata.bin", bytes: 243, algorithm: "sha256", digest: "7c151c6259c279aa7922d60e82c7851bbad1df10018b1cebc566aa6c2aee5e0f"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3/TextDecoder.mlmodelc/coremldata.bin", bytes: 637, algorithm: "sha256", digest: "f41a7939b47f7cf127aa69dfd8c552a141dc773b936bf8621aeffcd201fb9e30"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3/TextDecoder.mlmodelc/metadata.json", bytes: 4770, algorithm: "git-sha1", digest: "2819b5c39208bba1bf441644756b66c6b0ab2f29"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3/TextDecoder.mlmodelc/model.mil", bytes: 1010477, algorithm: "git-sha1", digest: "86f4dfb70c1a8bacea8ca20428386598eec38461"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3/TextDecoder.mlmodelc/model.mlmodel", bytes: 745579, algorithm: "sha256", digest: "680d8dfb7c7d8f1f852071ac7bdc96e55c696d0b822e70861045efb426b0a27b"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3/TextDecoder.mlmodelc/weights/weight.bin", bytes: 1813201716, algorithm: "sha256", digest: "680f398925225a313c62da0221aa0a58c9f1bffac5c36f20c449a70a7c9b1e55"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3/config.json", bytes: 1163, algorithm: "git-sha1", digest: "517e587af460e8be33f7ce25a74f6c84783dbfba"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3/generation_config.json", bytes: 2810, algorithm: "git-sha1", digest: "bb80d1d949760a83e859b8ee1fbaa256ee8894a5"),
    ]
    private static let turboModel: [Entry] = [
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3-v20240930_turbo/AudioEncoder.mlmodelc/analytics/coremldata.bin", bytes: 243, algorithm: "sha256", digest: "b58d36a7f4a729570b46b424ed8d847baefa07580e6cb9d47773ae738f8b845a"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3-v20240930_turbo/AudioEncoder.mlmodelc/coremldata.bin", bytes: 348, algorithm: "sha256", digest: "ffa9eb76e8e9d9be75a4d527e5249e61d67fd43081c5aa110fd24efa6c8c5ea3"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3-v20240930_turbo/AudioEncoder.mlmodelc/metadata.json", bytes: 1824, algorithm: "git-sha1", digest: "6649beb738361ff043fde0cfdc553ec58a555756"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3-v20240930_turbo/AudioEncoder.mlmodelc/model.mil", bytes: 7175750, algorithm: "git-sha1", digest: "50e06d13f4394c6fafb90d3001d4ec600bc426ad"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3-v20240930_turbo/AudioEncoder.mlmodelc/model.mlmodel", bytes: 441653, algorithm: "sha256", digest: "c5eb570c19871d7b0c59e0a84718cc9c8cde77a94273886de87e866961262e2c"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3-v20240930_turbo/AudioEncoder.mlmodelc/weights/weight.bin", bytes: 1273974400, algorithm: "sha256", digest: "98daf651a919978e28fe185daf55ce2f70085a8e59fa07fe8a4d08c87d368ae4"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3-v20240930_turbo/MelSpectrogram.mlmodelc/analytics/coremldata.bin", bytes: 243, algorithm: "sha256", digest: "c5be419f8622083ac7046306400643539f0e7577c843448c36defc090d41e7ce"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3-v20240930_turbo/MelSpectrogram.mlmodelc/coremldata.bin", bytes: 329, algorithm: "sha256", digest: "98efa1e351b759e078c4044668926d32bee886caf7596ae897e08e21da45565a"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3-v20240930_turbo/MelSpectrogram.mlmodelc/metadata.json", bytes: 1850, algorithm: "git-sha1", digest: "fa0c2e5993006c311ba50d307cf563ae10a16b5f"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3-v20240930_turbo/MelSpectrogram.mlmodelc/model.mil", bytes: 10143, algorithm: "git-sha1", digest: "16b67b0978ac178a7540e8520915d2473d4bae03"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3-v20240930_turbo/MelSpectrogram.mlmodelc/weights/weight.bin", bytes: 373376, algorithm: "sha256", digest: "009d9fb8f6b589accfa08cebf1c712ef07c3405229ce3cfb3a57ee033c9d8a49"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3-v20240930_turbo/TextDecoder.mlmodelc/analytics/coremldata.bin", bytes: 243, algorithm: "sha256", digest: "47703aed03fbfa5128e118cfe6519024006f953a53e921d66003f1412c27996c"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3-v20240930_turbo/TextDecoder.mlmodelc/coremldata.bin", bytes: 633, algorithm: "sha256", digest: "605dad4099a82cf2c7afe93e6d8e322f1c16d4160ab27bd017ec2517b81c1bdd"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3-v20240930_turbo/TextDecoder.mlmodelc/metadata.json", bytes: 4756, algorithm: "git-sha1", digest: "0ab0186a31088dc5c3f70ed8bed2e069aab244e0"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3-v20240930_turbo/TextDecoder.mlmodelc/model.mil", bytes: 132680, algorithm: "git-sha1", digest: "4fb605dbbe780cc7e67641c14b605797d1c3f952"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3-v20240930_turbo/TextDecoder.mlmodelc/model.mlmodel", bytes: 113164, algorithm: "sha256", digest: "03b79e4355e814c56239ea809e5d8f6432d70d74256bc9d70c27184fe9fcec48"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3-v20240930_turbo/TextDecoder.mlmodelc/weights/weight.bin", bytes: 343933748, algorithm: "sha256", digest: "47b2703aa37448e09cf2f06e45984fabd5ded4c34ba3400cec38a5294af39dc1"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3-v20240930_turbo/TextDecoderContextPrefill.mlmodelc/analytics/coremldata.bin", bytes: 243, algorithm: "sha256", digest: "97639d36c7b137ea51c3c39b175911788f4d4a601ab03cd67a4b14164c3145e1"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3-v20240930_turbo/TextDecoderContextPrefill.mlmodelc/coremldata.bin", bytes: 380, algorithm: "sha256", digest: "2c159f5c862ec187092ea58e755d8c0b298952e22f3d75da023d7693c1c7389e"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3-v20240930_turbo/TextDecoderContextPrefill.mlmodelc/metadata.json", bytes: 2240, algorithm: "git-sha1", digest: "0b95fc53b8ba1b1a2c456910e6a9d9b1df36d6ea"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3-v20240930_turbo/TextDecoderContextPrefill.mlmodelc/model.mil", bytes: 4092, algorithm: "git-sha1", digest: "3e58aef47f462dfe6e83a60084bf2f2b7f4e93e2"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3-v20240930_turbo/TextDecoderContextPrefill.mlmodelc/weights/weight.bin", bytes: 12288192, algorithm: "sha256", digest: "1310070082639173e9d81508c5f220692d489e85655aa6883cc1c7506da7fcfd"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3-v20240930_turbo/config.json", bytes: 1149, algorithm: "git-sha1", digest: "f6c3db01a3124f90b3bfbf3d58e47ba5de1f5ccd"),
        Entry(repository: "argmaxinc/whisperkit-coreml", revision: "0f63a7800b00dd0226abd051b906c246e1907482", path: "openai_whisper-large-v3-v20240930_turbo/generation_config.json", bytes: 2767, algorithm: "git-sha1", digest: "a023f6f947b0fc4ab7a2986a1c23b014836ec720"),
    ]
    private static let largeTokenizer: [Entry] = [
        Entry(repository: "openai/whisper-large-v3", revision: "06f233fe06e710322aca913c1bc4249a0d71fce1", path: "config.json", bytes: 1272, algorithm: "git-sha1", digest: "14c6c8cf48b64ebb1cb8b637e2b0fab3a9774972"),
        Entry(repository: "openai/whisper-large-v3", revision: "06f233fe06e710322aca913c1bc4249a0d71fce1", path: "tokenizer.json", bytes: 2480617, algorithm: "git-sha1", digest: "3a5e2ba63acdcac9a19ba56cf9bd27f185bfff61"),
        Entry(repository: "openai/whisper-large-v3", revision: "06f233fe06e710322aca913c1bc4249a0d71fce1", path: "tokenizer_config.json", bytes: 282843, algorithm: "git-sha1", digest: "06ffdc8308eae6bb7bd1fdd81e94b0a881a539ab"),
    ]
}

/// Streaming public model transfer: bytes written never exceed the independent manifest size.
/// A serial delegate queue plus lock-protected cancellation/continuation prevents double completion.
final class SpeechAssetTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL, expectedBytes: Int64, deadline: Double
    private let progress: @Sendable (Int64) -> Void
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var cancelled = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var failure: Error?
    private var timer: DispatchSourceTimer?
    init(destination: URL, expectedBytes: Int64, deadline: Double,
         configuration: URLSessionConfiguration = .ephemeral,
         progress: @escaping @Sendable (Int64) -> Void = { _ in }) {
        self.destination=destination; self.expectedBytes=expectedBytes; self.deadline=deadline
        self.configuration=configuration; self.progress=progress
    }
    static func allowed(_ url: URL) -> Bool {
        let hosts: Set<String> = ["huggingface.co","cdn-lfs.huggingface.co","cdn-lfs-us-1.huggingface.co",
            "cdn-lfs-eu-1.huggingface.co","cas-bridge.xethub.hf.co","us.aws.cdn.hf.co","eu.aws.cdn.hf.co"]
        return url.scheme == "https" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
            && hosts.contains(url.host?.lowercased() ?? "")
    }
    func start(_ url: URL) async throws {
        guard Self.allowed(url), expectedBytes > 0 else { throw MediaSpeechAssetManifest.Failure.downloadRefused }
        try MediaSpeechAssetManifest.safePath(destination)
        try MediaSpeechAssetManifest.check(deadline)
        try Data().write(to: destination, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        handle = try FileHandle(forWritingTo: destination)
        defer { try? handle?.close(); handle = nil }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelled { lock.unlock(); c.resume(throwing: CancellationError()); return }
                continuation=c
                let config=configuration
                config.httpCookieStorage=nil; config.httpShouldSetCookies=false; config.urlCredentialStorage=nil; config.urlCache=nil
                config.requestCachePolicy = .reloadIgnoringLocalCacheData
                let remaining=max(0.001,deadline-ProcessInfo.processInfo.systemUptime)
                config.timeoutIntervalForRequest=min(60,remaining); config.timeoutIntervalForResource=remaining
                let queue=OperationQueue(); queue.maxConcurrentOperationCount=1
                let session=URLSession(configuration:config,delegate:self,delegateQueue:queue); self.session=session
                let timer=DispatchSource.makeTimerSource(queue:.global(qos:.utility)); self.timer=timer
                timer.schedule(deadline:.now()+remaining); timer.setEventHandler { [weak session] in session?.invalidateAndCancel() };timer.resume()
                session.dataTask(with:url).resume();lock.unlock()
            }
        } onCancel: {
            self.lock.lock();self.cancelled=true;let session=self.session;self.lock.unlock()
            session?.invalidateAndCancel()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url=request.url,Self.allowed(url) else { failure=MediaSpeechAssetManifest.Failure.downloadRefused; completionHandler(nil);task.cancel();return }
        var clean=request;clean.setValue(nil,forHTTPHeaderField:"Authorization");clean.setValue(nil,forHTTPHeaderField:"Cookie")
        completionHandler(clean)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge,nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response=response as? HTTPURLResponse,response.statusCode==200,
              response.expectedContentLength == -1 || response.expectedContentLength == expectedBytes else {
            failure=MediaSpeechAssetManifest.Failure.downloadRefused;completionHandler(.cancel);return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try MediaSpeechAssetManifest.check(deadline)
            guard Int64(data.count)<=expectedBytes-written else { throw MediaSpeechAssetManifest.Failure.corrupt }
            try handle?.write(contentsOf:data);written+=Int64(data.count);progress(written)
        } catch { failure=error;dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        timer?.cancel();timer=nil
        lock.lock();let c=continuation;continuation=nil;let stopped=cancelled;self.session=nil;lock.unlock()
        session.finishTasksAndInvalidate()
        if stopped { c?.resume(throwing:CancellationError()) }
        else if let error=failure ?? error { c?.resume(throwing:error) }
        else if written != expectedBytes { c?.resume(throwing:MediaSpeechAssetManifest.Failure.corrupt) }
        else { c?.resume() }
    }
}
