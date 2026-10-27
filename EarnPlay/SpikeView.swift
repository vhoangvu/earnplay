import SwiftUI
import EarnPlayCore

/// Minimal T0.2 spike/debug screen: runs one fixed prompt on-device and
/// shows the round-trip latency. This is the screen the card's manual
/// Airplane Mode test uses (human checkpoint, not an automated step).
///
/// The model file is never bundled. Install it with
/// `Scripts/setup-model-spike.sh` (simulator) or copy a GGUF named
/// `EarnPlayModel.gguf` into the app's Documents (device). Without a
/// model the screen says so — it never invents a response.
struct SpikeView: View {
    @State private var selectedPrompt = 0
    @State private var responseText = ""
    @State private var statusText = "Model not loaded yet."
    @State private var coldText = "—"
    @State private var warmText = "—"
    @State private var isRunning = false
    @State private var runCount = 0
    @State private var runtime: ModelRuntime? = {
        guard let url = ModelRuntime.defaultModelURL() else { return nil }
        return ModelRuntime(modelPath: url)
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model spike (T0.2)")
                .font(.headline)
            Text(ModelRuntime.modelIdentifier)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(ModelRuntime.runtimeIdentifier)
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Prompt", selection: $selectedPrompt) {
                ForEach(SpikePrompts.all.indices, id: \.self) { index in
                    Text("Prompt \(index + 1)").tag(index)
                }
            }
            .pickerStyle(.segmented)

            Text(SpikePrompts.all[selectedPrompt])
                .font(.subheadline)

            Button(isRunning ? "Running…" : "Run prompt") {
                run()
            }
            .disabled(isRunning || runtime == nil)

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Cold (load + first run): \(coldText)")
                .font(.caption.monospacedDigit())
            Text("Warm (later runs): \(warmText)")
                .font(.caption.monospacedDigit())

            if !responseText.isEmpty {
                Text(responseText)
                    .font(.body)
                    .textSelection(.enabled)
            }
            if runtime == nil {
                Text("No model file found. Run Scripts/setup-model-spike.sh, or copy a GGUF as EarnPlayModel.gguf into Documents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private func run() {
        guard let runtime else { return }
        isRunning = true
        statusText = "Running on-device…"
        let prompt = SpikePrompts.all[selectedPrompt]
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try runtime.generate(prompt: prompt, maxTokens: 48)
                }.value
                runCount += 1
                responseText = result.response
                statusText = "Done. \(result.generatedTokenCount) tokens. No network used."
                let total = "\(Int(result.totalLatencyMs)) ms"
                if result.wasColdStart || runCount == 1 {
                    coldText = total
                } else {
                    warmText = total
                }
            } catch {
                statusText = "Failed: \(String(describing: error))"
            }
            isRunning = false
        }
    }
}
