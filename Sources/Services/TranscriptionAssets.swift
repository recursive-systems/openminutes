import Foundation
import Speech

/// Installs the on-device speech model assets for a locale, exposing
/// download progress (PRD B1). No-op when assets are already installed —
/// `onProgress` only fires when a download actually starts.
enum TranscriptionAssets {

    @MainActor
    static func ensureInstalled(
        for locale: Locale = .current,
        onProgress: (Progress) -> Void = { _ in }
    ) async throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) else { return }   // already installed

        onProgress(request.progress)
        try await request.downloadAndInstall()
    }
}
