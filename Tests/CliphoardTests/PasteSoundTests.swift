import Foundation
import XCTest
@testable import Cliphoard

@MainActor
final class PasteSoundTests: XCTestCase {
    func testPasteSoundIsOptInAndUsesItsOwnSavedChoice() throws {
        let suite = "cliphoard.paste-sound.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(Feedback.pasteSoundToPlay(in: defaults))

        defaults.set(true, forKey: "soundEnabled")
        defaults.set("Frog", forKey: "soundName")
        XCTAssertNil(Feedback.pasteSoundToPlay(in: defaults))

        defaults.set(true, forKey: "pasteSoundEnabled")
        XCTAssertEqual(Feedback.pasteSoundToPlay(in: defaults), "Pop")

        defaults.set("Tink", forKey: "pasteSoundName")
        defaults.set(false, forKey: "soundEnabled")
        XCTAssertEqual(Feedback.pasteSoundToPlay(in: defaults), "Tink")

        defaults.set(false, forKey: "pasteSoundEnabled")
        XCTAssertNil(Feedback.pasteSoundToPlay(in: defaults))
        XCTAssertEqual(defaults.string(forKey: "pasteSoundName"), "Tink")
    }
}
