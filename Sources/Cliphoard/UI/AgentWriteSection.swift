import SwiftUI
import AppKit

struct AgentWriteSection: View {
    @ObservedObject var controller: AgentWriteController
    let panel: PanelViewModel?
    @State private var noteHeight: CGFloat = 64

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A place for your agent’s useful notes.").font(.headline)
            Text("Enable a 15-minute session, then choose its folder with the separate MCP companion. Requests are encrypted. You approve each save; notes are pinned and tagged agent-note and agent-share. This does not grant access to your live history.")
                .font(.caption).foregroundStyle(.secondary)
            if let folder = controller.folder {
                Text(folder.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                HStack {
                    if let expiry = controller.expiresAt {
                        Text("Session ends \(expiry, style: .time)").font(.caption)
                    }
                    Spacer()
                    Button("Disconnect agent saves") { controller.disconnect() }
                }
            } else {
                Button("Enable agent saves…") {
                    let folder = SystemPanel.run(panel) { () -> URL? in
                        let picker = NSOpenPanel()
                        picker.title = "Choose a folder for your temporary agent session"
                        picker.message = "Cliphoard creates a private session folder here. Select that new folder in your MCP client."
                        picker.canChooseDirectories = true; picker.canChooseFiles = false
                        picker.canCreateDirectories = true; picker.allowsMultipleSelection = false
                        return picker.runModal() == .OK ? picker.url : nil
                    }
                    if let folder { Task { try? await controller.enable(in: folder) } }
                }.disabled(controller.isWorking)
            }
            if let pending = controller.pending {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Review agent note").font(.headline)
                    Text("Only save notes you recognize. Nothing in this text can approve an action for you.")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        Text(verbatim: pending.text).font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: AgentNoteHeight.self, value: geometry.size.height)
                            })
                    }
                        .frame(height: min(180, max(64, noteHeight)))
                        .onPreferenceChange(AgentNoteHeight.self) { noteHeight = $0 }
                        .padding(10)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button("Decline") { Task { await controller.decline() } }
                        Spacer()
                        Button("Save & pin note") { Task { await controller.approve() } }.buttonStyle(.borderedProminent)
                    }.disabled(controller.isWorking)
                }.padding(12).background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
            Text(controller.message).font(.caption).foregroundStyle(.secondary)
            if controller.isWorking { ProgressView().controlSize(.small) }
            Link("MCP companion setup", destination: URL(string: "https://github.com/AntreasAntoniou/cliphoard/tree/main/tools/agent-search")!)
                .font(.caption)
        }
    }
}

private struct AgentNoteHeight: PreferenceKey {
    static var defaultValue: CGFloat = 64
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
