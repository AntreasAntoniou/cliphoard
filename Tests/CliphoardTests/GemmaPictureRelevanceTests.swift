import XCTest
@testable import Cliphoard

final class GemmaPictureRelevanceTests: XCTestCase {
    private func vector(_ x: Float, _ y: Float) -> [Float] {
        var v = [Float](repeating: 0, count: 768); v[0] = x; v[1] = y; return v
    }
    func testGenericImageAttractionDoesNotCountAsQueryRelevance() {
        let image = vector(1, 0)
        let generic = [vector(0.72, 0.694), vector(0.71, 0.704)]
        XCTAssertNil(GemmaPictureRelevance.score(query: vector(0.69, 0.724), image: image, backgrounds: generic))
        XCTAssertNotNil(GemmaPictureRelevance.score(query: vector(0.84, 0.543), image: image, backgrounds: generic))
    }
    func testMeasuredPublicImageWitnessKeepsOnlyRelevantPicture() {
        let background: [Float] = [0.723543, 0.717906, 0.703245, 0.725956]
        let rows: [([Float], Int?)] = [
            ([0.838509, 0.623360, 0.680791, 0.651127], 0),
            ([0.636720, 0.771539, 0.643227, 0.672491], 1),
            ([0.663975, 0.609997, 0.814885, 0.617981], 2),
            ([0.683004, 0.683995, 0.659449, 0.707023], nil),
            ([0.698922, 0.674679, 0.654501, 0.699390], nil),
            ([0.583911, 0.626431, 0.587868, 0.643317], nil),
            ([0.589625, 0.567207, 0.611725, 0.621131], nil),
            ([0.645710, 0.633109, 0.589184, 0.672867], nil),
            ([0.670251, 0.651365, 0.671509, 0.695147], nil)
        ]
        for (raw, expected) in rows {
            let retained = raw.indices.filter { GemmaPictureRelevance.margin(similarity: raw[$0], background: background[$0]) != nil }
            XCTAssertEqual(retained, expected.map { [$0] } ?? [])
        }
    }
    func testMissingOrInvalidBackgroundCannotBlessAnImage() {
        let image = vector(1, 0)
        XCTAssertNil(GemmaPictureRelevance.score(query: image, image: image, backgrounds: []))
        XCTAssertNil(GemmaPictureRelevance.score(query: image, image: [1], backgrounds: [image]))
        XCTAssertNil(GemmaPictureRelevance.margin(similarity: .nan, background: 0.5))
        XCTAssertNil(GemmaPictureRelevance.margin(similarity: 0.75, background: 0.72),
                     "Small generic or neighbouring-class attraction must not become a confident match")
    }
}
