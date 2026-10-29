import Foundation

/// A bounded encrypted blob codec. Persistence, lifecycle and privacy admission belong to the caller.
struct MediaSearchCache {
    enum Failure: Error { case invalidRecord, encryptionUnavailable, unreadable, identityMismatch }
    enum Modality: String, Codable { case video, audio }
    struct Identity: Codable, Equatable {
        var contentSHA256: String
        var modelRevision: String
        var preprocessingRevision: String
        var samplingRevision: String
    }
    struct TimedVector: Codable, Equatable {
        var modality: Modality
        var start: Double
        var end: Double
        var vector: [Float]
    }
    struct Record: Codable, Equatable {
        var identity: Identity
        var duration: Double
        var vectors: [TimedVector]
    }
    static let maximumBlobBytes = 4 * 1024 * 1024
    private let sealBytes: (Data) -> Data?
    private let openBytes: (Data) -> Data?
    init(seal: @escaping (Data) -> Data? = { Crypto.sealStrict($0) },
         open: @escaping (Data) -> Data? = { Crypto.open($0) }) {
        sealBytes = seal; openBytes = open
    }
    func seal(_ record: Record) throws -> Data {
        try validate(record)
        let plain = try JSONEncoder().encode(record)
        guard plain.count <= Self.maximumBlobBytes,
              let sealed = sealBytes(plain), sealed.starts(with: Data("enc1:".utf8)),
              sealed != plain, sealed.count <= Self.maximumBlobBytes + 128 else {
            throw Failure.encryptionUnavailable
        }
        return sealed
    }
    func open(_ sealed: Data, expected: Identity) throws -> Record {
        guard sealed.count <= Self.maximumBlobBytes + 128,
              sealed.starts(with: Data("enc1:".utf8)),
              let plain = openBytes(sealed), plain != sealed,
              plain.count <= Self.maximumBlobBytes,
              !plain.starts(with: Data("enc1:".utf8)),
              let record = try? JSONDecoder().decode(Record.self, from: plain) else { throw Failure.unreadable }
        try validate(record)
        guard record.identity == expected else { throw Failure.identityMismatch }
        return record
    }
    func validate(_ record: Record) throws {
        let id = record.identity
        guard id.contentSHA256.utf8.count == 64,
              id.contentSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              [id.modelRevision, id.preprocessingRevision, id.samplingRevision].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }),
              record.duration.isFinite, record.duration > 0,
              record.vectors.count <= 480 else { throw Failure.invalidRecord }
        var dimensions: [Modality: Int] = [:]
        var counts: [Modality: Int] = [:]
        var previous: [Modality: Double] = [:]
        for item in record.vectors {
            guard item.start.isFinite, item.end.isFinite, item.start >= 0,
                  item.end >= item.start, item.end <= record.duration,
                  item.start >= previous[item.modality, default: 0],
                  !item.vector.isEmpty, item.vector.count <= 4096,
                  item.vector.allSatisfy(\.isFinite),
                  item.vector.contains(where: { $0 != 0 }),
                  dimensions[item.modality].map({ $0 == item.vector.count }) ?? true else { throw Failure.invalidRecord }
            dimensions[item.modality] = item.vector.count
            counts[item.modality, default: 0] += 1
            guard counts[item.modality]! <= (item.modality == .video ? 360 : 120) else { throw Failure.invalidRecord }
            previous[item.modality] = item.start
        }
    }
}
