import SwiftUI
import EarnPlayCore

/// Minimal T0.2 spike/debug screen: runs one fixed prompt on-device.
///
/// Inference uses the PERSISTED production registry's active bundle
/// artifacts (T5.3 F2/F6): the model file and prompt texts come from
/// `VersionRegistry.inferenceArtifacts()`, so after a rollback the
/// rolled-back model/prompts are the ones actually loaded — never
/// the current artifacts under an old label. Without a model the
/// screen says so — it never invents a response.
struct SpikeView: View {
    @State private var selectedPrompt = 0
    @State private var responseText = ""
    @State private var statusText = "Model not loaded yet."
    @State private var coldText = "—"
    @State private var warmText = "—"
    @State private var isRunning = false
    @State private var runCount = 0

    @State private var artifacts: InferenceArtifacts?
    @State private var artifactError: String?
    @State private var registry: VersionRegistry?
    @State private var versionStatus = ""
    @State private var runtime: ModelRuntime?

    init() {
        var resolved: InferenceArtifacts?
        var message: String?
        var loaded: VersionRegistry?
        do {
            let reg = try VersionRegistry.production()
            loaded = reg
            resolved = try reg.inferenceArtifacts()
        } catch {
            message = "Version artifacts unavailable: \(String(describing: error))"
        }
        _artifacts = State(initialValue: resolved)
        _artifactError = State(initialValue: message)
        _registry = State(initialValue: loaded)
        if let url = resolved?.modelURL {
            _runtime = State(initialValue: ModelRuntime(modelPath: url))
        }
    }

    private func reloadArtifacts() {
        do {
            let reg: VersionRegistry
            if let registry { reg = registry } else { reg = try VersionRegistry.production(); registry = reg }
            let resolved = try reg.inferenceArtifacts()
            artifacts = resolved
            artifactError = nil
            runtime = resolved.modelURL.map { ModelRuntime(modelPath: $0) }
            selectedPrompt = 0
            versionStatus = "Active bundle is now \(reg.activeBundleID)."
        } catch {
            versionStatus = "Failed: \(String(describing: error))"
        }
    }

    private func performVersionAction(_ action: (VersionRegistry) throws -> Void) {
        do {
            let reg: VersionRegistry
            if let registry { reg = registry } else { reg = try VersionRegistry.production(); registry = reg }
            try action(reg)
            reloadArtifacts()
        } catch {
            versionStatus = "Failed: \(String(describing: error))"
        }
    }

    private var prompts: [String] { artifacts?.prompts ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model spike (T0.2)")
                .font(.headline)
            if let artifacts {
                Text("Model version: \(artifacts.modelVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Prompt version: \(artifacts.promptVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let artifactError {
                Text(artifactError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            Text("Version rollback (this app)")
                .font(.subheadline.bold())
            Button("Register active bundle as previous known-good") {
                performVersionAction { try $0.registerActiveAsPreviousKnownGood() }
            }
            Button("Roll back to previous known-good") {
                performVersionAction { try $0.rollbackToPreviousKnownGood() }
            }
            Button("Roll forward to current") {
                performVersionAction { try $0.select(bundleID: "current") }
            }
            if !versionStatus.isEmpty {
                Text(versionStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !prompts.isEmpty {
                Picker("Prompt", selection: $selectedPrompt) {
                    ForEach(prompts.indices, id: \.self) { index in
                        Text("Prompt \(index + 1)").tag(index)
                    }
                }
                .pickerStyle(.segmented)

                Text(prompts[min(selectedPrompt, prompts.count - 1)])
                    .font(.subheadline)
            }

            Button(isRunning ? "Running…" : "Run prompt") {
                run()
            }
            .disabled(isRunning || runtime == nil || prompts.isEmpty)

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
        guard let runtime, !prompts.isEmpty else { return }
        isRunning = true
        statusText = "Running on-device…"
        let prompt = prompts[min(selectedPrompt, prompts.count - 1)]
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
