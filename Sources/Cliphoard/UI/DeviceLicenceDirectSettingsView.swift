#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE && !APP_STORE
import SwiftUI

/// The setup descriptor contains a bearer handle; keep it in a secure edit field,
/// clear it on dispatch and never copy it into published state or diagnostics.
@MainActor
struct DeviceLicenceDirectSettingsView: View {
    @ObservedObject var runtime: DeviceLicenceDirectRuntime
    @State private var bootstrap = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let session = runtime.session {
                if let receipt = session.approvedReceipt {
                    Text("Approval \(receipt.receiptID) · issued \(Date(timeIntervalSince1970: Double(receipt.issuedAt)).formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary).textSelection(.enabled)
                }
                DeviceLicenceApplicationPanel(session: session)
                    .onAppear { session.openPanel() }
                    .onDisappear { session.closePanel() }
            } else {
                HStack {
                    SecureField("Setup code from your purchase email", text: $bootstrap)
                        .textFieldStyle(.roundedBorder)
                    Button("Set up Pro") {
                        let value = bootstrap.trimmingCharacters(in: .whitespacesAndNewlines)
                        bootstrap = ""
                        runtime.importBootstrap(value)
                    }
                    .disabled(bootstrap.isEmpty || runtime.isWorking || runtime.lifecycle != .running)
                }
                Button("Restore saved setup") { runtime.restoreBootstrap() }
                    .disabled(runtime.isWorking || runtime.lifecycle != .running)
            }
            if runtime.isWorking { ProgressView().controlSize(.small) }
            if let failure = runtime.failure {
                Text(message(failure)).font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .controlSize(.small)
    }
    private func message(_ failure: DeviceLicenceDirectApplicationFailure) -> String {
        switch failure {
        case .invalidBootstrap: return "That setup code could not be verified. Check the code in your purchase email."
        case .scopeConflict: return "This Mac already has a different saved setup. Its existing approval has been kept."
        case .storageUnavailable: return "Saved setup is unavailable. Try restoring it again when storage is available."
        case .cancelled: return "Setup was cancelled."
        case .busy: return "Setup is already in progress."
        case .stopped: return "Restart Cliphoard to continue setup."
        case .invalidConfiguration, .sessionUnavailable: return "Pro setup is unavailable in this build."
        }
    }
}
#endif
