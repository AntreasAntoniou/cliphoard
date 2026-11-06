import SwiftUI
import AppKit

/// Presentation policy is kept separate from authority: only the controller can
/// grant a mode, and choosing an elevated row does not grant it before confirmation.
enum AgentWritePermissionPresentation {
    typealias Permission = AgentWriteController.Permission

    static func requiresConfirmation(from current: Permission, to next: Permission) -> Bool {
        let rank: [Permission: Int] = [.askEveryTime: 0, .session: 1, .fullAccess: 2]
        return rank[next, default: 0] > rank[current, default: 0]
    }

    static func isAvailable(_ mode: Permission, connected: Bool, current: Permission = .askEveryTime) -> Bool {
        mode != .session || connected || current == .session
    }

    static func confirmationTitle(_ mode: Permission) -> String {
        mode == .fullAccess ? "Remember automatic agent saves?" : "Allow automatic saves this session?"
    }

    static func confirmationMessage(_ mode: Permission) -> String {
        let permission = mode == .fullAccess
            ? "New plain-text notes can be saved and pinned without individual approval in this and future connections you explicitly enable. This choice is remembered until you change it. A new Full access connection stays open until you disconnect or quit Cliphoard. An existing timed connection keeps its current deadline; reconnect to remove that deadline."
            : "New plain-text notes can be saved and pinned without individual approval for the rest of this connection. Ask every time returns when the session ends, within 15 minutes."
        return permission + " Agents cannot edit or delete clips, read your live history, or reveal sensitive content. Notes flagged as sensitive are refused."
    }

    static func connectionExplanation(permission: Permission, connected: Bool,
                                      lifetime: AgentWriteProtocol.Lifetime?) -> String {
        guard connected else {
            switch permission {
            case .fullAccess:
                return "Full access is remembered, but no connection is open. Enable a connection when you want your agent to save notes; it stays open until you disconnect or quit Cliphoard."
            case .session:
                return "The previous connection is closed. Enable a new 15-minute session to save notes automatically; Ask every time returns when it ends."
            case .askEveryTime:
                return "Enable a 15-minute session, then choose its folder in the MCP companion. Each note waits for your approval in the clipboard pane."
            }
        }
        if lifetime == .whileAppRuns {
            return "New notes save automatically until you disconnect or quit Cliphoard. Choosing a lower permission closes this connection immediately; your agent must reconnect."
        }
        switch permission {
        case .askEveryTime: return "Every note waits for your approval in the clipboard pane. This connection keeps its 15-minute deadline."
        case .session: return "New notes save automatically for this 15-minute connection only. Disconnecting or expiry restores Ask every time."
        case .fullAccess: return "New notes save automatically, but this connection keeps its timed deadline. Disconnect and enable a new connection to stay connected until you quit."
        }
    }
}

struct AgentWriteSection: View {
    @ObservedObject var controller: AgentWriteController
    let panel: PanelViewModel?
    @State private var pendingPermission: AgentWriteController.Permission?

    private var permissionAlert: Binding<Bool> {
        Binding(get: { pendingPermission != nil }, set: { if !$0 { pendingPermission = nil } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Useful agent notes, on your terms.").font(.headline)
            Text("Choose when your agent needs permission to add a note. Saved notes are pinned and tagged agent-note and agent-share.")
                .font(.caption).foregroundStyle(.secondary)

            VStack(spacing: 7) {
                permissionRow(.askEveryTime, symbol: "hand.raised", title: "Ask every time",
                              detail: "Review each note before it is saved.", badge: "Default")
                permissionRow(.session, symbol: "clock", title: "This session",
                              detail: controller.folder == nil
                                ? (controller.permission == .session ? "Enable a new 15-minute session. Then ask again when it ends." : "Connect first, then allow automatic saves for 15 minutes.")
                                : "Save automatically for a 15-minute session. Then ask again.", badge: "Temporary")
                permissionRow(.fullAccess, symbol: "sparkles", title: "Full access",
                              detail: "Save automatically until you quit or disconnect. Remember this choice.", badge: "Remembered")
            }

            Label("New notes only. No edits, deletion, live-history access or sensitive previews.", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(controller.folder == nil ? "Agent saves are off" : "Encrypted connection active",
                          systemImage: controller.folder == nil ? "pause.circle" : "checkmark.shield")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if let expiry = controller.expiresAt {
                        Text("Ends \(expiry, style: .time)").font(.caption).foregroundStyle(.secondary)
                    } else if controller.folder != nil, controller.connectionLifetime == .whileAppRuns {
                        Text("Until you quit or disconnect").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(connectionExplanation).font(.caption).foregroundStyle(.secondary)
                if let folder = controller.folder {
                    Text(folder.path).font(.system(.caption2, design: .monospaced))
                        .lineLimit(2).textSelection(.enabled).help(folder.path)
                    HStack {
                        Button("Disconnect") { controller.disconnect() }
                        if controller.permission != .askEveryTime {
                            Button("Ask every time") { controller.setPermission(.askEveryTime) }
                        }
                    }
                } else {
                    Button(controller.permission == .fullAccess ? "Enable agent connection…" : "Enable 15-minute session…") { chooseSessionFolder() }
                        .buttonStyle(.borderedProminent).tint(.purple)
                        .disabled(controller.isWorking)
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))

            if !controller.pendingNotes.isEmpty {
                Text("\(controller.pendingNotes.count) clips await review in the clipboard pane.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(controller.message).font(.caption).foregroundStyle(.secondary)
            if controller.isWorking { ProgressView().controlSize(.small) }
            Link("MCP companion setup", destination: URL(string: "https://github.com/AntreasAntoniou/cliphoard/tree/main/tools/agent-search")!)
                .font(.caption)
        }
        .alert(AgentWritePermissionPresentation.confirmationTitle(pendingPermission ?? .session),
               isPresented: permissionAlert, presenting: pendingPermission) { mode in
            Button("Cancel", role: .cancel) { pendingPermission = nil }
            Button(mode == .fullAccess ? "Remember automatic saves" : "Allow for this session") {
                controller.setPermission(mode)
                pendingPermission = nil
            }
        } message: { mode in
            Text(AgentWritePermissionPresentation.confirmationMessage(mode))
        }
        .onChange(of: controller.folder) { folder in
            if folder == nil, pendingPermission == .session { pendingPermission = nil }
        }
    }

    private var connectionExplanation: String {
        AgentWritePermissionPresentation.connectionExplanation(permission: controller.permission,
            connected: controller.folder != nil, lifetime: controller.connectionLifetime)
    }

    private func permissionRow(_ mode: AgentWriteController.Permission, symbol: String,
                               title: String, detail: String, badge: String) -> some View {
        let selected = controller.permission == mode
        let available = AgentWritePermissionPresentation.isAvailable(mode, connected: controller.folder != nil,
            current: controller.permission)
        return Button {
            if AgentWritePermissionPresentation.requiresConfirmation(from: controller.permission, to: mode) {
                pendingPermission = mode
            } else {
                controller.setPermission(mode)
            }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                    .foregroundStyle(selected ? Color.purple : Color.secondary)
                    .frame(width: 25)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(title).font(.subheadline.weight(.semibold))
                        Text(badge).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    }
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 5)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.purple : Color.secondary.opacity(0.55))
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.purple.opacity(0.10) : Color.primary.opacity(0.025),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.purple.opacity(0.48) : Color.primary.opacity(0.09), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).disabled(!available)
        .accessibilityLabel(title + ". " + detail)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    private func chooseSessionFolder() {
        let folder = SystemPanel.run(panel) { () -> URL? in
            let picker = NSOpenPanel()
            picker.title = "Choose a folder for your agent connection"
            picker.message = "Cliphoard creates a private session folder here. Select that new folder in your MCP client."
            picker.canChooseDirectories = true; picker.canChooseFiles = false
            picker.canCreateDirectories = true; picker.allowsMultipleSelection = false
            return picker.runModal() == .OK ? picker.url : nil
        }
        if let folder { Task { try? await controller.enable(in: folder) } }
    }
}
