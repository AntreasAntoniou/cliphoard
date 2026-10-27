#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE && !APP_STORE
import SwiftUI

/// Presentation only: the application owner explicitly starts and stops the session.
/// Rebuilding this value never creates a new flow or performs restore/network work.
@MainActor
struct DeviceLicenceApplicationPanel: View {
    @ObservedObject var session: DeviceLicenceApplicationSession
    var body: some View {
        DeviceLicenceApprovalContent(state: session.approvalState,
            request: { session.requestApprovalForThisMac() },
            submitCode: { session.submitEmailCode($0) },
            retry: { session.retrySameOperation() }, cancel: { session.cancelLocalWork() },
            differentCode: { session.useDifferentCode() },
            restore: { session.restoreSavedApproval() },
            importReceipt: { session.importApprovedReceipt($0) })
            .disabled(session.lifecycle != .running)
    }
}
#endif
