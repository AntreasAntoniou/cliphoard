import SwiftUI
import AppKit

/// The three things you can do to a `.file` clip's file. One enum so the card menu, the
/// row menu and the inspector cannot drift apart, and so "does this need the file to still
/// exist" is answered once rather than three times.
enum FileVerb: String, CaseIterable {
    case open, reveal, copyPath

    var title: String {
        switch self {
        case .open:     return "Open"
        case .reveal:   return "Reveal in Finder"
        case .copyPath: return "Copy Path"
        }
    }

    /// Whether the file must still be on disk. Copy Path does NOT: a path you can paste
    /// into a terminal is exactly what you want when you are trying to find out where the
    /// file went, so disabling it on a missing file removes the one useful action left.
    var needsFile: Bool { self != .copyPath }
}

enum FileClipAction {
    /// Why Open and Reveal cannot run, or nil when they can. Returns the REASON rather than
    /// a Bool: a greyed control with no explanation sends someone hunting for another way
    /// to do the thing, so a caller cannot disable an item without holding the sentence
    /// that explains it.
    ///
    /// `exists` is injected so the miss can be tested without a filesystem — the miss is
    /// the case that matters and the one nobody exercises by hand.
    static func unavailableReason(
        path: String?,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        guard let path, !path.isEmpty else { return "no path recorded" }
        return exists(path) ? nil : "file is missing"
    }

    /// A menu title that carries its own reason. A disabled SwiftUI menu item shows no
    /// tooltip, so the title is the only place the explanation can live.
    static func title(_ verb: FileVerb, reason: String?) -> String {
        guard verb.needsFile, let reason else { return verb.title }
        return "\(verb.title) (\(reason))"
    }

    /// The in-bar notice for the paths that have no menu item to grey out — ⌘O and the
    /// double-click. Names the path: "moved or deleted" is only actionable if you can see
    /// WHICH file.
    static func missingMessage(path: String?) -> String {
        guard let path, !path.isEmpty else {
            return "That clip has no file path recorded, so there is nothing to open."
        }
        return "That file is no longer at \(path) — it was moved or deleted since it was copied."
    }
}

/// The three menu items, built once and used by BOTH context menus, so "the card carries
/// the affordance" is a fact about one view rather than three copies that can drift.
struct FileClipMenuItems: View {
    let item: ClipItem
    var perform: (FileVerb) -> Void

    var body: some View {
        let reason = FileClipAction.unavailableReason(path: item.filePath)
        ForEach(FileVerb.allCases, id: \.self) { verb in
            Button(FileClipAction.title(verb, reason: reason)) { perform(verb) }
                .disabled(verb.needsFile && reason != nil)
        }
    }
}
