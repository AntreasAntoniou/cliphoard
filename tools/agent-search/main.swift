import AppKit
import UniformTypeIdentifiers

// Only this native user interaction selects an archive and collects its passphrase.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.activate(ignoringOtherApps: true)
let panel = NSOpenPanel()
panel.title = "Choose a Cliphoard export to share with your agent"
panel.message = "Eligible text clips tagged agent-share will be available to this MCP client. Returned clips may be sent to its model provider."
panel.allowedContentTypes = [UTType(filenameExtension: "cliphoard") ?? .data]
guard panel.runModal() == .OK, let url = panel.url else { exit(1) }
let alert = NSAlert()
alert.messageText = "Unlock this Cliphoard export for agent search?"
alert.informativeText = url.lastPathComponent
let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
password.placeholderString = "Export passphrase"
alert.accessoryView = password
alert.window.initialFirstResponder = password
alert.addButton(withTitle: "Share tagged clips")
alert.addButton(withTitle: "Cancel")
guard alert.runModal() == .alertFirstButtonReturn else { exit(1) }
do {
    let items = try AgentArchive.read(url, passphrase: password.stringValue)
    password.stringValue = ""
    FileHandle.standardOutput.write(try JSONEncoder().encode(items))
} catch {
    password.stringValue = ""
    // Errors from JSON, paths and protected archive fields never enter the client log.
    exit(2)
}
