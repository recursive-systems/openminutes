import SwiftUI

/// Credits for third-party work shipped inside the app.
///
/// Not optional politeness: the bundled diarization models are CC-BY-4.0, and
/// that licence requires attribution wherever they are distributed. Removing
/// this screen while the models ship would put the app out of licence.
struct AcknowledgementsView: View {
    var body: some View {
        List {
            Section {
                Text("Speaker diarization uses pyannote models, converted to Core ML by FluidInference and bundled with this app. They run entirely on your device.")
                    .font(.callout)
                LabeledContent("Models", value: "pyannote · CC BY 4.0")
                LabeledContent("Conversion", value: "FluidInference")
                LabeledContent("FluidAudio", value: "Apache 2.0")
                Link("pyannote-audio", destination: URL(string: "https://github.com/pyannote/pyannote-audio")!)
                Link("FluidAudio", destination: URL(string: "https://github.com/FluidInference/FluidAudio")!)
            } header: {
                Text("Speaker Detection")
            } footer: {
                Text("Hervé Bredin et al., “pyannote.audio: neural building blocks for speaker diarization.”")
            }

            Section {
                Text("Transcription and summaries use Apple's on-device Speech and Foundation Models frameworks.")
                    .font(.callout)
            } header: {
                Text("Speech")
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}
