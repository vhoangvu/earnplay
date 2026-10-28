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
///
/// Round 4 F8: registry resolution (which hashes the model) and
/// snapshot copies run off the main actor; the view shows a loading
/// state and disables conflicting actions until they finish. The
/// `ModelRuntime` is bound to the resolved content digest, so a
/// model file replaced after resolution is rejected at load (F1)
/// instead of running under the old version stamp.
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
    @State private var isResolving = true
    @State private var isVersionActionRunning = false

    private var prompts: [String] { artifacts?.prompts ?? [] }
    private var versionActionsDisabled: Bool { isRunning || isResolving || isVersionActionRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model spike (T0.2)")
                .font(.headline)
            if isResolving {
                Text("Resolving version artifacts…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
            .disabled(versionActionsDisabled)
            Button("Roll back to previous known-good") {
                performVersionAction { try $0.rollbackToPreviousKnownGood() }
            }
            .disabled(versionActionsDisabled)
            Button("Roll forward to current") {
                performVersionAction { try $0.select(bundleID: "current") }
            }
            .disabled(versionActionsDisabled)
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
            .disabled(isRunning || isResolving || runtime == nil || prompts.isEmpty)

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
            if runtime == nil && !isResolving {
                Text("No model file found. Run Scripts/setup-model-spike.sh, or copy a GGUF as EarnPlayModel.gguf into Documents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .task { await reloadArtifactsAsync() }
    }

    /// F9/F10: a successful reload replaces the runtime, so prior
    /// results are cleared and the run counter resets; a failed
    /// reload clears artifacts/runtime so Run stays disabled.
    private func applyResolved(_ resolved: InferenceArtifacts, registry reg: VersionRegistry) {
        artifacts = resolved
        artifactError = nil
        runtime = resolved.modelURL.map {
            ModelRuntime(modelPath: $0, expectedContentDigest: resolved.modelContentDigest,
                         expectedModelVersion: resolved.modelContentDigest == nil ? resolved.modelVersion : nil)
        }
        registry = reg
        selectedPrompt = 0
        responseText = ""
        coldText = "—"
        warmText = "—"
        runCount = 0
        statusText = "Model not loaded yet."
    }

    private func applyResolutionFailure(_ error: Error) {
        artifacts = nil
        runtime = nil
        artifactError = "Version artifacts unavailable: \(String(describing: error))"
        responseText = ""
        coldText = "—"
        warmText = "—"
        runCount = 0
    }

    private func reloadArtifactsAsync() async {
        isResolving = true
        defer { isResolving = false }
        do {
            let reg = registry
            let (loaded, resolved) = try await Task.detached(priority: .userInitiated) {
                let r = try reg ?? VersionRegistry.production()
                return (r, try r.inferenceArtifacts())
            }.value
            applyResolved(resolved, registry: loaded)
            versionStatus = "Active bundle is now \(try loaded.activeBundleID)."
        } catch {
            applyResolutionFailure(error)
            versionStatus = "Failed: \(String(describing: error))"
        }
    }

    private func performVersionAction(_ action: @escaping @Sendable (VersionRegistry) throws -> Void) {
        guard !versionActionsDisabled else { return }
        isVersionActionRunning = true
        Task {
            defer { isVersionActionRunning = false }
            do {
                let reg = registry
                let loaded = try await Task.detached(priority: .userInitiated) { () -> VersionRegistry in
                    let r = try reg ?? VersionRegistry.production()
                    try action(r)
                    return r
                }.value
                registry = loaded
                await reloadArtifactsAsync()
            } catch {
                versionStatus = "Failed: \(String(describing: error))"
            }
        }
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
