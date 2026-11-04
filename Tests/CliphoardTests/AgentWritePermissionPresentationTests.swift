import XCTest
@testable import Cliphoard

final class AgentWritePermissionPresentationTests: XCTestCase {
    func testElevationsRequireConfirmationAndDowngradesDoNot() {
        typealias P = AgentWriteController.Permission
        for (before, after) in [(P.askEveryTime, P.session), (.askEveryTime, .fullAccess), (.session, .fullAccess)] {
            XCTAssertTrue(AgentWritePermissionPresentation.requiresConfirmation(from: before, to: after))
        }
        for (before, after) in [(P.fullAccess, P.session), (.fullAccess, .askEveryTime), (.session, .askEveryTime)] {
            XCTAssertFalse(AgentWritePermissionPresentation.requiresConfirmation(from: before, to: after))
        }
        for mode in P.allCases {
            XCTAssertFalse(AgentWritePermissionPresentation.requiresConfirmation(from: mode, to: mode))
        }
    }

    func testSessionCannotBeSelectedWhileDisconnected() {
        XCTAssertFalse(AgentWritePermissionPresentation.isAvailable(.session, connected: false))
        XCTAssertTrue(AgentWritePermissionPresentation.isAvailable(.session, connected: true))
        XCTAssertTrue(AgentWritePermissionPresentation.isAvailable(.session, connected: false, current: .session))
        for mode in [AgentWriteController.Permission.askEveryTime, .fullAccess] {
            XCTAssertTrue(AgentWritePermissionPresentation.isAvailable(mode, connected: false))
        }
    }

    func testConfirmationNamesLimitsAndRememberedChoice() {
        let session = AgentWritePermissionPresentation.confirmationMessage(.session)
        let remembered = AgentWritePermissionPresentation.confirmationMessage(.fullAccess)
        XCTAssertTrue(session.contains("Ask every time returns"))
        XCTAssertTrue(remembered.contains("future connections you explicitly enable"))
        XCTAssertTrue(remembered.contains("remembered until you change it"))
        XCTAssertTrue(remembered.contains("until you disconnect or quit Cliphoard"))
        XCTAssertTrue(remembered.contains("existing timed connection keeps its current deadline"))
        XCTAssertTrue(session.contains("15 minutes"))
        for message in [session, remembered] {
            XCTAssertTrue(message.contains("cannot edit or delete clips"))
            XCTAssertTrue(message.contains("read your live history"))
            XCTAssertTrue(message.contains("sensitive"))
        }
    }

    func testExplanationUsesActualConnectionLifetimeAndPendingSession() {
        let timedFull = AgentWritePermissionPresentation.connectionExplanation(permission: .fullAccess,
            connected: true, lifetime: .bounded)
        let continuous = AgentWritePermissionPresentation.connectionExplanation(permission: .fullAccess,
            connected: true, lifetime: .whileAppRuns)
        let pendingSession = AgentWritePermissionPresentation.connectionExplanation(permission: .session,
            connected: false, lifetime: nil)
        let disconnectedFull = AgentWritePermissionPresentation.connectionExplanation(permission: .fullAccess,
            connected: false, lifetime: nil)
        XCTAssertTrue(timedFull.contains("keeps its timed deadline"))
        XCTAssertTrue(timedFull.contains("enable a new connection"))
        XCTAssertTrue(continuous.contains("until you disconnect or quit Cliphoard"))
        XCTAssertTrue(continuous.contains("lower permission closes this connection immediately"))
        XCTAssertTrue(pendingSession.contains("previous connection is closed"))
        XCTAssertTrue(pendingSession.contains("new 15-minute session"))
        XCTAssertTrue(disconnectedFull.contains("no connection is open"))
    }
}
