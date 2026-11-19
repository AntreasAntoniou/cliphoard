#if !APP_STORE || LOCAL_PERFORMANCE_PRO
import SwiftUI

struct DirectUpdateNotice: View {
    @ObservedObject var updates = DirectUpdateChecker.shared
    var body: some View {
        if updates.showsNotice, let release = updates.available {
            HStack {
                Label("\(release.label) is available", systemImage: "arrow.down.circle")
                Spacer()
                Button("View update") { updates.openRelease() }
                Button("Later") { updates.dismissNotice() }
            }
            .font(.caption).controlSize(.small)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.10))
        }
    }
}

struct DirectUpdateSettingsView: View {
    @ObservedObject var updates = DirectUpdateChecker.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
        Toggle("Automatically check for updates", isOn: $updates.automaticChecks)
        Text("Checks GitHub daily while Cliphoard is running. Works in Free and Pro. No clipboard or licence data is sent. Updates are downloaded and installed only when you choose.")
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Text(updates.checking ? "Checking for updates…" : updates.message)
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Check for Updates") { Task { await updates.check(manual: true) } }
                .disabled(updates.checking)
                .controlSize(.small)
        }
        if let release = updates.available {
            Button("View \(release.label)") { updates.openRelease() }.controlSize(.small)
        }
        Text("macOS may ask to allow notifications when an update is found. If notifications are off, new updates still appear in Cliphoard.")
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
