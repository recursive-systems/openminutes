import Foundation

extension MarkdownDocument {
    /// The document export writes for a recording. One constructor, so the
    /// real exporter and the test pipeline cannot drift apart on which keys
    /// a recording carries into its file.
    init(
        recording: Recording,
        audioFileName: String?,
        device: String = MarkdownDocument.currentDevice(),
        generator: String = MarkdownDocument.currentGenerator()
    ) {
        self.init(
            id: recording.id.uuidString.lowercased(),
            title: recording.title,
            recorded: recording.createdAt,
            duration: recording.duration,
            transcript: recording.transcript,
            summary: recording.summary,
            audioFileName: audioFileName,
            device: device,
            generator: generator,
            language: recording.transcriptLanguage,
            speakers: recording.speakerNames,
            ref: recording.ref
        )
    }
}
