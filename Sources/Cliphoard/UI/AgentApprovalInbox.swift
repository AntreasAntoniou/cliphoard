import SwiftUI

/// Pending requests are not clipboard history and cannot be pasted or searched.
/// Each button captures one immutable request ID, never a moving queue position.
struct AgentApprovalInbox: View {
    @ObservedObject var controller: AgentWriteController

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(controller.pendingNotes) { note in
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Agent clip · awaiting permission", systemImage: "hand.raised")
                            .font(.caption.weight(.semibold)).foregroundStyle(.purple)
                        ScrollView {
                            Text(verbatim: note.text)
                                .font(.body).frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        Text("Not saved yet").font(.caption2).foregroundStyle(.secondary)
                        HStack {
                            Button("Reject") { Task { await controller.decline(id: note.id, expectedBytes: note.bytes) } }
                                .accessibilityIdentifier("agent-reject-" + note.id.uuidString.lowercased())
                            Spacer()
                            Button("Accept") { Task { await controller.approve(id: note.id, expectedBytes: note.bytes) } }
                                .buttonStyle(.borderedProminent).tint(.purple)
                                .accessibilityIdentifier("agent-accept-" + note.id.uuidString.lowercased())
                        }.disabled(controller.isWorking)
                    }
                    .padding(14).frame(width: 290)
                    .frame(maxHeight: .infinity)
                    .background(Color.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.purple.opacity(0.3)))
                }
            }.padding(.horizontal, 14).padding(.vertical, 10)
        }
        .accessibilityLabel("Agent clips awaiting permission")
    }
}
