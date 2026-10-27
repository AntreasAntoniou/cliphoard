#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE && !APP_STORE
import XCTest
import SwiftUI
@testable import Cliphoard

@MainActor
final class DeviceLicenceApplicationPanelTests: XCTestCase {
    func testRebuiltPanelUsesSameSessionAndDoesNoWorkOnConstruction() async throws {
        let fixture = try ApplicationFixture(); defer { fixture.cleanup() }
        let session = try fixture.session()
        for _ in 0..<5 {
            session.openPanel()
            let panel = DeviceLicenceApplicationPanel(session: session)
            _ = panel.body
            session.closePanel()
        }
        let counts = await (fixture.identityStorage.reads, fixture.keys.availabilityChecks,
                            fixture.transport.begins.count, fixture.transport.approvals.count)
        XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0)
        XCTAssertEqual(counts.2, 0); XCTAssertEqual(counts.3, 0)
        XCTAssertEqual(session.lifecycle, .idle); XCTAssertFalse(session.isPanelPresented)
        XCTAssertEqual(fixture.io.readCalls, 0); XCTAssertEqual(fixture.ids.calls, 0)
    }
}
#endif
