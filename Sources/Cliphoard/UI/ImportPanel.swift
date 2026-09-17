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
    ///
    /// Routed through `SystemPanel` — which it was not, and that was a live bug: this
    /// called `runModal()` with NO guard at all, so opening the picker hid the bar
    /// underneath it. Settings is rendered in-bar, so the host window is the floating panel
    /// and `onResignKey` takes it away the moment the open panel becomes key.
    func chooseStore(for candidate: Candidate?, store: ClipStore, panel viewModel: PanelViewModel?) {
        let chosen = SystemPanel.run(viewModel) { () -> URL? in
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.prompt = "Preview"
            panel.message = "Pick the other manager's database or export."
            return panel.runModal() == .OK ? panel.url : nil
        }
        guard let url = chosen else { return }
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

    /// GATE 4. Free may PREVIEW — the dry run is the safety mechanism and paywalling it
    /// would make the untested-adapter warning meaningless — but may not COMMIT.
    ///
    /// The entitlement arrives as a VALUE (the `HistoryReaper` idiom) rather than being read
    /// from a global here, so the refusal is testable without a signed key, and so no future
    /// caller can reach the write path without having said which entitlement it holds.
    func commit(_ candidate: Candidate, path: String? = nil, store: ClipStore,
                entitlement: Entitlement) {
        guard entitlement.isPro else {
            // Says what it refused and why. A migration button that quietly does nothing is
            // how a user concludes the importer is broken rather than paid.
            result = "Importing from another manager is Cliphoard Pro. Your preview above is "
                   + "real — nothing was written."
            return
        }
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
    /// Handed to `ImportModel.chooseStore`, which must suspend hide-on-resign while its
    /// `NSOpenPanel` is up. No button offers it yet — the picker is reached from the
    /// caller that will — but the guard is wired now, because it is the thing that was
    /// missing and a test pins it.
    var panel: PanelViewModel?

    /// Let the user point at a store Cliphoard did not find on its own.
    func chooseOther(_ candidate: ImportModel.Candidate) {
        model.chooseStore(for: candidate, store: store, panel: panel)
    }

    /// Read from the store, which holds it as a value read at the boundary. Observing the
    /// store means a key pasted in the section above swaps this panel from pitch to button
    /// in the same frame, with no relaunch.
    private var entitlement: Entitlement { store.entitlement }

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
            if entitlement.isPro {
                HStack {
                    Spacer()
                    Button("Import \(preview.total)") {
                        model.commit(candidate, store: store, entitlement: entitlement)
                    }
                    .controlSize(.small)
                    .disabled(preview.total == 0 || store.safeMode)
                }
            } else {
                // UPSELL 4 — the highest-converting screen in the app, and the only pitch
                // here built from the user's OWN data: their clips, their other manager,
                // counted by the same writer that would do the import. No invented number.
                ProPitchCard(
                    message: "Bringing them across is Cliphoard Pro. The preview above is "
                           + "real and it cost you nothing — this is the same tally the "
                           + "import itself would produce. " + Licence.pitch,
                    headline: "\(preview.total) clip\(preview.total == 1 ? "" : "s") still "
                            + "sitting in \(candidate.source.name)")
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}
