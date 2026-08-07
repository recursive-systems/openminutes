import SwiftUI

/// The export destinations, named by where files land rather than by the
/// mechanism that puts them there (PRD C1). Shared by Settings and the
/// not-configured banner so the wording can't drift between them;
/// onboarding presents the same three as full-width rows.
///
/// Choosing a destination is free — the Pro gate applies at export time
/// (PRD C5), so picking one never opens a paywall.
struct ExportDestinationMenu<Label: View>: View {
    @Environment(ExportService.self) private var exporter
    @Environment(ProcessingCoordinator.self) private var processor

    /// Presents the system folder picker; the caller owns the importer so
    /// it can refresh its own state when a folder comes back.
    let chooseCustomFolder: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            if exporter.iCloudAvailable {
                Button {
                    Task {
                        if await exporter.useICloudContainer() {
                            processor.exportPendingRecordings()
                        }
                    }
                } label: {
                    SwiftUI.Label("iCloud Drive", systemImage: "icloud")
                }
            }
            Button {
                exporter.useLocalFolder()
                processor.exportPendingRecordings()
            } label: {
                SwiftUI.Label("On My iPhone", systemImage: "iphone")
            }
            Button(action: chooseCustomFolder) {
                SwiftUI.Label("Choose a folder…", systemImage: "folder.badge.plus")
            }
        } label: {
            label()
        }
    }
}
