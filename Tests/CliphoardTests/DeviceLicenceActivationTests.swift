#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE
import XCTest
@testable import Cliphoard

final class DeviceLicenceActivationTests: XCTestCase {
    func testOutageHoldRefundAndBadReplacementPreserveApprovedOfflineReceipt() async throws {
        let receipt = try await DeviceLicenceTestFixture().approved()
        let existing = DeviceLicenceActivation(approvedReceipt: receipt)
        for failure in [DeviceLicenceActivation.Failure.unavailable, .heldForReview, .approvalRejected, .invalidReceipt] {
            let next = existing.reducing(.begin(requestID: "request-a"))
                .reducing(.emailPending(requestID: "request-a"))
                .reducing(.failed(requestID: "request-a", reason: failure))
            XCTAssertEqual(next.receipt, receipt)
            XCTAssertEqual(next.phase, .failed(requestID: "request-a", reason: failure))
        }
    }

    func testOnlyCurrentPendingRequestCanReplaceReceipt() async throws {
        let receipt = try await DeviceLicenceTestFixture().approved()
        let state = DeviceLicenceActivation().reducing(.begin(requestID: "old"))
            .reducing(.begin(requestID: "new"))
        XCTAssertEqual(state.reducing(.verified(requestID: "old", receipt: receipt)), state)
        XCTAssertEqual(state.reducing(.failed(requestID: "old", reason: .unavailable)), state)
        XCTAssertEqual(state.reducing(.emailPending(requestID: "old")), state)
        let approved = state.reducing(.verified(requestID: "new", receipt: receipt))
        XCTAssertEqual(approved.receipt, receipt)
        XCTAssertEqual(approved.phase, .idle)
        XCTAssertEqual(approved.reducing(.failed(requestID: "new", reason: .approvalRejected)), approved)
    }

    func testUnsolicitedOrLateCompletionCannotActivate() async throws {
        let receipt = try await DeviceLicenceTestFixture().approved()
        let empty = DeviceLicenceActivation()
        XCTAssertEqual(empty.reducing(.verified(requestID: "unknown", receipt: receipt)), empty)
        let failed = empty.reducing(.begin(requestID: "request"))
            .reducing(.failed(requestID: "request", reason: .unavailable))
        XCTAssertEqual(failed.reducing(.verified(requestID: "request", receipt: receipt)), failed)
    }
}
#endif
