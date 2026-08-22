import SwiftUI
import AppKit

/// The Settings surface for bringing history in from another clipboard manager.
///
/// The engine already existed and was reachable only as a command-line flag inside the app
/// bundle. Someone migrating from Paste does not open Terminal and type a path into an
/// `.app` — so the feature was, in practice, not shipped. The site advertised "bring your
/// history" and the only door was `--import-from`.
///
/// THE FLOW IS DELIBERATELY TWO-STEP: scan, then dry run, then confirm. It mirrors the CLI's
/// safety model rather than simplifying it away, because the risk it guards against is real —
/// nine of the ten adapters have NEVER been executed against a real store, since none of
/// those apps is installed on the machine they were written on. A one-click "Import" would
/// take an untested parser and write its output straight into someone's clip history.
///
/// So the tally is shown BEFORE anything is written, and the confirm button states the count.
/// If an adapter is misreading a store, the kind breakdown is where it shows: 4,000 clips all
/// arriving as `file`, or a text-only manager reporting images, is visible in one glance and
/// invisible in a spinner.
@MainActor
final class ImportModel: ObservableObject {

    struct Candidate: Identifiable {
        var id: String { source.id }
        let source: ClipImporters.Source
        let path: String
    }

    /// Result of a dry run — what WOULD be imported, per kind.
    struct Preview {
        let sourceID: String
        let byKind: [(String, Int)]
        let total: Int
        let skippedDuplicate: Int
        let skippedUnparsable: Int
        let skippedEmpty: Int
    }

    @Published private(set) var candidates: [Candidate] = []
    @Published private(set) var preview: Preview?
    @Published private(set) var busy: String?
    @Published private(set) var result: String?

    /// Only sources whose store actually exists here. Listing all ten would present nine
    /// dead rows to someone who uses one clipboard manager.
    func scan() {
        candidates = ClipImporters.all.compactMap { source in
            guard let path = ClipImporters.resolve(source) else { return nil }
            return Candidate(source: source, path: path)
        }
        result = candidates.isEmpty
            ? "No other clipboard managers found on this Mac."
            : nil
    }

    /// Let the user point at an export or a store we did not find automatically — the Paste
    /// history that started all this was an export folder, not an installed app.
    func chooseStore(for candidate: Candidate?, store: ClipStore) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Preview"
        panel.message = "Pick the other manager's database or export."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let candidate {
            dryRun(candidate, path: url.path, store: store)
        }
    }

    func dryRun(_ candidate: Candidate, path: String? = nil, store: ClipStore) {
        guard let read = candidate.source.read else {
            result = "\(candidate.source.name): no importer yet — \(candidate.source.note)"
            return
        }
        busy = "Reading \(candidate.source.name)…"
        preview = nil
        result = nil
        var tally = PasteImport.Tally()
        let staged = read(path ?? candidate.path, &tally)
        // Count against the real writer so the preview reflects dedup exactly, then discard.
        ClipImporters.write(staged, marker: "import-\(candidate.source.id)",
                            store: store, dryRun: true, tally: &tally)
        preview = Preview(sourceID: candidate.source.id,
                          byKind: tally.byKind.sorted { $0.value > $1.value }.map { ($0.key, $0.value) },
                          total: tally.imported,
                          skippedDuplicate: tally.skippedDuplicate,
                          skippedUnparsable: tally.skippedUnparsable,
                          skippedEmpty: tally.skippedEmpty)
        busy = nil
    }

    func commit(_ candidate: Candidate, path: String? = nil, store: ClipStore) {
        guard let read = candidate.source.read else { return }
        busy = "Importing \(candidate.source.name)…"
        var tally = PasteImport.Tally()
        let staged = read(path ?? candidate.path, &tally)
        ClipImporters.write(staged, marker: "import-\(candidate.source.id)",
                            store: store, dryRun: false, tally: &tally)
        busy = nil
        preview = nil
        result = "Imported \(tally.imported) clip\(tally.imported == 1 ? "" : "s") from "
            + "\(candidate.source.name), tagged “import-\(candidate.source.id)”."
    }
}

struct ImportSection: View {
    @ObservedObject var model: ImportModel
    @ObservedObject var store: ClipStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.candidates.isEmpty && model.result == nil {
                HStack {
                    Text("Bring your clips over from another manager.")
                        .foregroundStyle(.secondary).font(.system(size: 12))
                    Spacer()
                    Button("Look for apps") { model.scan() }.controlSize(.small)
                }
            }

            ForEach(model.candidates) { candidate in
                candidateRow(candidate)
            }

            if let preview = model.preview,
               let candidate = model.candidates.first(where: { $0.id == preview.sourceID }) {
                previewBox(preview, candidate: candidate)
            }

            if let busy = model.busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if let result = model.result {
                Text(result).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private func candidateRow(_ candidate: ImportModel.Candidate) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.source.name)
                // The status is shown to the USER, not hidden in a comment, because it is
                // the difference between "this has been run against real data" and "this
                // has never been executed". They are consenting to the second one.
                if candidate.source.confidence != .verified {
                    Text("untested importer — preview before you commit")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            Spacer()
            Button("Preview…") { model.dryRun(candidate, store: store) }
                .controlSize(.small)
                .disabled(candidate.source.read == nil || store.safeMode)
        }
    }

    private func previewBox(_ preview: ImportModel.Preview,
                            candidate: ImportModel.Candidate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(preview.total) clip\(preview.total == 1 ? "" : "s") would be imported")
                .font(.system(size: 12, weight: .semibold))
            // The kind breakdown IS the check. An adapter misreading a store shows up here
            // — everything arriving as one kind, or a text-only manager reporting images —
            // and shows up nowhere in a progress bar.
            ForEach(preview.byKind, id: \.0) { kind, n in
                Text("   \(n) \(kind)").font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if preview.skippedDuplicate > 0 || preview.skippedUnparsable > 0 || preview.skippedEmpty > 0 {
                Text("   skipped: \(preview.skippedDuplicate) already here, "
                     + "\(preview.skippedUnparsable) unreadable, \(preview.skippedEmpty) empty")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Import \(preview.total)") { model.commit(candidate, store: store) }
                    .controlSize(.small)
                    .disabled(preview.total == 0 || store.safeMode)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}
