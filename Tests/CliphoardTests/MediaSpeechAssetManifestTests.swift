import XCTest
import CryptoKit
@testable import Cliphoard

final class MediaSpeechAssetManifestTests: XCTestCase {
    func temporary() throws -> URL {
        let temporaryPath = FileManager.default.temporaryDirectory.path
        // Foundation may retain /var's alias even after resolvingSymlinksInPath().
        let physicalPath = temporaryPath.hasPrefix("/var/") ? "/private" + temporaryPath : temporaryPath
        let url=URL(fileURLWithPath:physicalPath,isDirectory:true).appendingPathComponent("speech-assets-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) };return url
    }
    func testDirectoryURLAncestorWalkStopsAtRoot() throws {
        let root = try temporary()
        let directoryURL = URL(fileURLWithPath: root.path, isDirectory: true)
        try MediaSpeechAssetManifest.safePath(directoryURL)
        try MediaSpeechAssetManifest.safePath(URL(fileURLWithPath: "/", isDirectory: true))
        XCTAssertThrowsError(try MediaSpeechAssetManifest.safePath(directoryURL.appendingPathComponent("../outside")))
        XCTAssertFalse(MediaSpeechAssetManifest.localCandidateExists(model: .small, root: directoryURL))
    }

    func testIndependentDigestRefusesSameSizeTamperingAndMissingFiles() throws {
        let root=try temporary(), file=root.appendingPathComponent("file")
        let original=Data("original".utf8)
        let digest=SHA256.hash(data:original).map { String(format:"%02x",$0) }.joined()
        let e=MediaSpeechAssetManifest.Entry(repository:"openai/whisper-small",revision:MediaSpeechAssetManifest.smallRevision,path:"file",bytes:8,algorithm:"sha256",digest:digest)
        try original.write(to:file)
        try MediaSpeechAssetManifest.verifyFile(file,entry:e,deadline:ProcessInfo.processInfo.systemUptime+10)
        try Data("tampered".utf8).write(to:file)
        XCTAssertThrowsError(try MediaSpeechAssetManifest.verifyFile(file,entry:e,deadline:ProcessInfo.processInfo.systemUptime+10))
        XCTAssertEqual(try Data(contentsOf:file),Data("tampered".utf8))
        try FileManager.default.removeItem(at:file)
        XCTAssertThrowsError(try MediaSpeechAssetManifest.verifyFile(file,entry:e,deadline:ProcessInfo.processInfo.systemUptime+10))
    }
    func testPinnedAllModelInventoriesAndGitBlobHash() throws {
        XCTAssertEqual(MediaSpeechModel.small.downloadBytes,489252581)
        XCTAssertEqual(MediaSpeechModel.largeV3.downloadBytes,3093084631)
        XCTAssertEqual(MediaSpeechModel.turbo.downloadBytes,1641229178)
        for model in MediaSpeechModel.allCases {
            let rows=MediaSpeechAssetManifest.entries(for:model)
            XCTAssertEqual(rows.count,model == .turbo ? 27 : 22)
            XCTAssertEqual(Set(rows.map(\.relativePath)).count,rows.count)
            for row in rows { try MediaSpeechAssetManifest.validate(row); XCTAssertEqual(row.revision.count,40) }
        }
        let root=try temporary(), file=root.appendingPathComponent("plain.json"), bytes=Data("{}".utf8)
        try bytes.write(to:file);var hash=Insecure.SHA1();hash.update(data:Data("blob 2\0".utf8));hash.update(data:bytes)
        let row=MediaSpeechAssetManifest.Entry(repository:"openai/whisper-small",revision:MediaSpeechAssetManifest.smallRevision,path:"plain.json",bytes:2,algorithm:"git-sha1",digest:hash.finalize().map{String(format:"%02x",$0)}.joined())
        try MediaSpeechAssetManifest.verifyFile(file,entry:row,deadline:ProcessInfo.processInfo.systemUptime+10)
    }
    func testExplicitDownloadCannotReblessBadCache() async throws {
        let root=try temporary();let directory=MediaSpeechAssetManifest.directory(for:.small,in:root)
        // Tiny actual pinned metadata entry; no model bytes or provider calls are needed.
        let row=MediaSpeechAssetManifest.entries(for:.small).first { $0.bytes < 1000 }!
        let file=directory.appendingPathComponent(row.relativePath)
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        let corrupt=Data(repeating:0,count:Int(row.bytes));try corrupt.write(to:file)
        for allow in [false,true] {
            do { _ = try await MediaSpeechAssetManifest.prepare(model:.small,root:root,allowDownload:allow);XCTFail("corrupt cache accepted") }
            catch { XCTAssertEqual(error as? MediaSpeechAssetManifest.Failure,.corrupt) }
            XCTAssertEqual(try Data(contentsOf:file),corrupt)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent("small-integrity.json").path))
    }
    func testExtraLoadableFileAndSymlinkRefused() throws {
        let root=try temporary();let rows=MediaSpeechAssetManifest.entries(for:.small)
        let folder=root.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-small")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let extra=folder.appendingPathComponent("TextDecoderContextPrefill.mlmodelc")
        try Data("not pinned".utf8).write(to:extra)
        XCTAssertThrowsError(try MediaSpeechAssetManifest.checkInventory(rows,root:root))
        try FileManager.default.removeItem(at:extra)
        try FileManager.default.createSymbolicLink(at:extra,withDestinationURL:root)
        XCTAssertThrowsError(try MediaSpeechAssetManifest.checkInventory(rows,root:root))
    }
    final class FakeProtocol: URLProtocol, @unchecked Sendable {
        static var mode="success"
        static var started: XCTestExpectation?
        static var stopped: XCTestExpectation?
        override class func canInit(with request:URLRequest)->Bool { true }
        override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
        override func startLoading() {
            Self.started?.fulfill()
            if Self.mode == "stall" { return }
            let response=HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:nil)!
            client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:Data(Self.mode == "oversize" ? "four".utf8 : "one".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() { Self.stopped?.fulfill() }
    }
    func testStreamingTransferCapsBytesAndUsesExactAllowedHosts() async throws {
        let root=try temporary(), config=URLSessionConfiguration.ephemeral
        config.protocolClasses=[FakeProtocol.self]
        XCTAssertTrue(SpeechAssetTransfer.allowed(URL(string:"https://huggingface.co/model")!))
        for url in ["http://huggingface.co/x","https://evil.huggingface.co/x","https://user:pass@huggingface.co/x","https://huggingface.co:444/x"] {
            XCTAssertFalse(SpeechAssetTransfer.allowed(URL(string:url)!))
        }
        FakeProtocol.started=nil;FakeProtocol.stopped=nil
        FakeProtocol.mode="success"
        let valid=root.appendingPathComponent("valid")
        try await SpeechAssetTransfer(destination:valid,expectedBytes:3,deadline:ProcessInfo.processInfo.systemUptime+5,configuration:config).start(URL(string:"https://huggingface.co/mock")!)
        XCTAssertEqual(try Data(contentsOf:valid),Data("one".utf8))
        FakeProtocol.mode="oversize"
        let over=root.appendingPathComponent("over")
        do { try await SpeechAssetTransfer(destination:over,expectedBytes:3,deadline:ProcessInfo.processInfo.systemUptime+5,configuration:config).start(URL(string:"https://huggingface.co/mock")!);XCTFail() } catch {}
        XCTAssertLessThanOrEqual(try Data(contentsOf:over).count,3)
    }
    func testCancellationCancelsActualSessionTask() async throws {
        let root=try temporary(),config=URLSessionConfiguration.ephemeral;config.protocolClasses=[FakeProtocol.self]
        FakeProtocol.mode="stall";FakeProtocol.started=expectation(description:"started");FakeProtocol.stopped=expectation(description:"stopped")
        defer { FakeProtocol.started=nil;FakeProtocol.stopped=nil }
        let transfer=SpeechAssetTransfer(destination:root.appendingPathComponent("partial"),expectedBytes:3,deadline:ProcessInfo.processInfo.systemUptime+5,configuration:config)
        let task=Task { try await transfer.start(URL(string:"https://huggingface.co/mock")!) }
        await fulfillment(of:[FakeProtocol.started!],timeout:2)
        task.cancel()
        do { try await task.value;XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of:[FakeProtocol.stopped!],timeout:2)
    }
}
