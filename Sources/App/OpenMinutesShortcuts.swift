import AppIntents

/// Siri phrases + Shortcuts gallery entries; zero user setup (PRD C4).
/// App target only — the extension must not duplicate shortcut metadata.
struct OpenMinutesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Start an \(.applicationName) recording",
                "Start recording with \(.applicationName)",
                "Record a meeting with \(.applicationName)",
            ],
            shortTitle: "Start Recording",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: StopAndProcessIntent(),
            phrases: [
                "Stop the \(.applicationName) recording",
                "Stop recording with \(.applicationName)",
            ],
            shortTitle: "Stop Recording",
            systemImageName: "stop.circle"
        )
    }
}
