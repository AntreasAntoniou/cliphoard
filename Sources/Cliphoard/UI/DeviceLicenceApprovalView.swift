#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE && !APP_STORE
import SwiftUI

/// Standalone, externally owned flow. Construction, appearance and disappearance
/// perform no identity, storage, clipboard, browser or network operation.
@MainActor
struct DeviceLicenceApprovalView: View {
    @ObservedObject var flow: DeviceLicenceApprovalFlow
    var body: some View {
        DeviceLicenceApprovalContent(state: flow.state,
            request: { flow.requestApprovalForThisMac() },
            submitCode: { flow.submitEmailCode($0) },
            retry: { flow.retrySameOperation() }, cancel: { flow.cancelLocalWork() },
            differentCode: { flow.useDifferentCode() },
            restore: { flow.restoreSavedApproval() },
            importReceipt: { flow.importApprovedReceipt($0) })
    }
}

struct DeviceLicenceApprovalPresentation {
    let state: DeviceLicenceApprovalState
    var title: String {
        switch state.phase {
        case .ready: return state.isApproved ? "Approved for offline use" : "Approve this Mac"
        case .awaitingCode: return "Check your email"
        case .retryable: return "Approval needs attention"
        case .cancelled: return "Stopped on this Mac"
        case .recoveryRequired: return "Check saved approval"
        case .working(let activity):
            switch activity {
            case .restoring: return "Recovering saved approval"
            case .preparingIdentity: return "Preparing this Mac"
            case .requesting: return "Requesting approval"
            case .preparingApproval, .approving: return "Approving this Mac"
            case .saving: return "Saving approval"
            }
        }
    }
    var message: String {
        if let notice = state.notice {
            switch notice {
            case .approvalQueued:
                return "Approval has been requested for the email address on your purchase. Enter the code here when it arrives."
            case .invalidCode:
                return "That code could not be used. Paste the complete approval code from your email."
            case .challengeExpired:
                return "The approval window has ended on this Mac. You can explicitly request a new approval to continue."
            case .activationRejected:
                return state.canUseDifferentCode
                    ? "That approval was not accepted. Retry the same request, or choose to enter a different code."
                    : "That request was not accepted. You can retry the same request."
            case .unavailable: return "Approval is unavailable right now. You can try the same operation again when you are ready."
            case .outcomeUnknown:
                return "The reply did not confirm the result. Retry the same request to check it; this does not start a different approval or request another email."
            case .invalidResponse: return "The reply could not be verified. No approval has been granted from that reply. Retry the same request to check its result."
            case .identityUnavailable: return "Secure approval is unavailable on this Mac right now. Try again when this Mac is ready."
            case .identityMissing: return "This Mac's saved identity could not be found. Local recovery cannot create a replacement."
            case .identityChanged: return "Secure approval on this Mac needs recovery. Nothing has been reset or replaced."
            case .invalidReceipt: return "That receipt could not be verified for this Mac. No existing approval was removed."
            case .savedApprovalMissing: return "The local check found no saved approval. You can import the approved receipt from your email or continue your pending request."
            case .storageUnavailable: return "Saved approval could not be read or saved. Try local recovery again. No existing approval was removed."
            case .savedDataProblem: return "The saved approval needs recovery. It has been kept unchanged; importing a replacement cannot repair it automatically."
            case .cancelled: return "Waiting stopped here. Any request already sent may still complete. No saved approval has been removed."
            case .commitUncertain:
                return "Saving may have finished. Recover saved approval before trying again. This local check can also confirm that nothing was saved; it will not send another request."
            case .recovered: return "Your saved approval was verified on this Mac. No connection is needed to use it."
            }
        }
        if case .working = state.phase { return "You can stop waiting. A request already sent may still complete." }
        return state.isApproved
            ? "This Mac can use Pro offline indefinitely. No further online check is required."
            : "Request email approval for this Mac, or recover an approval you already have."
    }
    var retryTitle: String? {
        switch state.retry {
        case .sameRequest: return "Retry same request"
        case .prepareCode: return "Retry code submission"
        case .saveReceipt: return "Retry saving approval"
        case .existingIdentity: return "Check this Mac again"
        case .resumeCode: return "Continue code entry"
        case .restore: return "Retry local recovery"
        case nil: return nil
        }
    }
}

/// Pure presentation with explicit actions, also usable by synthetic offscreen fixtures.
@MainActor
struct DeviceLicenceApprovalContent: View {
    let state: DeviceLicenceApprovalState
    let request: () -> Void
    let submitCode: (String) -> Void
    let retry: () -> Void
    let cancel: () -> Void
    let differentCode: () -> Void
    let restore: () -> Void
    let importReceipt: (String) -> Void
    @State private var code = ""
    @State private var receipt = ""

    private var presentation: DeviceLicenceApprovalPresentation { .init(state: state) }
    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: state.isApproved ? "checkmark.seal.fill" : "desktopcomputer")
                        .font(.system(size: 30)).foregroundStyle(state.isApproved ? Color.green : Color.accentColor)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(presentation.title).font(.title2.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text(presentation.message).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if state.isApproved && state.phase != .ready {
                    Label("Your existing approval remains available offline.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
                }
                if case .working = state.phase { ProgressView().controlSize(.small) }
                if state.canRequest {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("This requests approval by email for the Mac you are using. Only request it for a Mac you personally own.")
                            .fixedSize(horizontal: false, vertical: true)
                        Button(state.notice == .challengeExpired ? "Request a new approval" : "Request approval for this Mac", action: request)
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("deviceApproval.request")
                    }
                }
                if state.canEnterCode {
                    VStack(alignment: .leading, spacing: 10) {
                        SecureField("Approval code from your email", text: $code)
                            .textFieldStyle(.roundedBorder).accessibilityLabel("Email approval code")
                            .accessibilityIdentifier("deviceApproval.code")
                            .onSubmit(approveCode)
                        Button("Approve this Mac", action: approveCode)
                            .buttonStyle(.borderedProminent).disabled(code.isEmpty)
                    }
                }
                if presentation.retryTitle != nil || state.canCancel || state.canUseDifferentCode {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { pendingActions.fixedSize() }
                        VStack(alignment: .leading, spacing: 10) { pendingActions }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recover approval on this Mac").font(.headline).accessibilityAddTraits(.isHeader)
                    Text("Check a saved approval, or paste the approved receipt from your email. The receipt must be for this Mac. No connection is needed.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Recover saved approval", action: restore)
                        .disabled(!state.canRestore).accessibilityIdentifier("deviceApproval.restore")
                    SecureField("Approved receipt from your email", text: $receipt)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Approved receipt")
                        .disabled(!state.canImport).accessibilityIdentifier("deviceApproval.receipt")
                    Button("Import approved receipt") {
                        let value = receipt; receipt = ""; importReceipt(value)
                    }
                    .disabled(!state.canImport || receipt.isEmpty)
                    .accessibilityIdentifier("deviceApproval.import")
                }
                Text("Each Mac you personally own can be approved by email. There is no fixed device limit. Once approved, this Mac can use Pro offline indefinitely.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("deviceApproval.policy")
                    .id("deviceApproval.policy")
            }
            .padding(24).frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(minWidth: 300, minHeight: 300)
        .onDisappear { code = ""; receipt = "" }
    }
    @ViewBuilder private var pendingActions: some View {
        if let title = presentation.retryTitle {
            Button(title, action: retry).accessibilityIdentifier("deviceApproval.retry")
        }
        if state.canUseDifferentCode { Button("Enter a different code", action: differentCode) }
        if state.canCancel {
            Button("Cancel") { code = ""; receipt = ""; cancel() }
                .help("Stops waiting here. A request already sent may still complete.")
        }
    }
    private func approveCode() {
        guard state.canEnterCode, !code.isEmpty else { return }
        let value = code; code = ""; submitCode(value)
    }
}
#endif
