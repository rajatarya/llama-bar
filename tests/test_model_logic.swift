// Test the pure model logic used by the menu bar app.
// Compile + run:  swiftc -o /tmp/test-model-logic tests/test_model_logic.swift LlamaBar/ModelLogic.swift && /tmp/test-model-logic
import Foundation

@main
struct TestRunner {
    static var failures = 0

    static func check(_ cond: Bool, _ name: String) {
        if cond { print("  ✓ \(name)") } else { failures += 1; print("  ✗ \(name)") }
    }

    static func main() {
        let root = FileManager.default.currentDirectoryPath
        let configPath = root + "/models.json"

        // MARK: Config loading (against the real models.json)

        guard let cfg = ModelsConfig.load(from: configPath) else {
            print("✗ models.json did not load"); exit(1)
        }
        check(true, "models.json loads")
        check(cfg.models[cfg.default_model] != nil, "default_model is a configured model")
        check(cfg.models.count >= 4, "at least 4 models configured")

        for (id, model) in cfg.models {
            check(!model.name.isEmpty, "\(id) has a name")
            check(model.ctx_size > 0 && model.ngl > 0 && model.batch_size > 0 && model.ubatch_size > 0,
                  "\(id) has ctx_size/ngl/batch_size/ubatch_size")
        }

        // MARK: Discovery parsing

        check(parseDiscoveredModels("[\"a\", \"b\"]") == ["a", "b"], "parses JSON array")
        check(parseDiscoveredModels("garbage").isEmpty, "garbage → empty")
        check(parseDiscoveredModels("[]").isEmpty, "empty array → empty")

        // MARK: Running-model resolution (quant matching against model_path)

        let q4 = "bartowski/Muse-Glimmer-30B-GGUF:Q4_K_M"
        let q5 = "bartowski/Muse-Glimmer-30B-GGUF:Q5_K_M"
        let bf16 = "unsloth/Muse-Glimmer-30B-GGUF:BF16"
        let ds = "unsloth/DeepSeek-V4-Flash-0731-GGUF:UD-Q2_K_XL"

        check(cfg.modelId(forRunningPath: "/models--bartowski--Muse-Glimmer-30B-GGUF/snapshots/x/ggml-model-q4_k_m.gguf") == q4,
              "resolves Q4_K_M from file name")
        check(cfg.modelId(forRunningPath: "/models--bartowski--Muse-Glimmer-30B-GGUF/snapshots/x/ggml-model-q5_k_m.gguf") == q5,
              "resolves Q5_K_M from file name")
        check(cfg.modelId(forRunningPath: "/models--unsloth--Muse-Glimmer-30B-GGUF/snapshots/x/ggml-model-bf16.gguf") == bf16,
              "resolves BF16 from file name")
        check(cfg.modelId(forRunningPath: "/models--unsloth--DeepSeek-V4-Flash-0731-GGUF/snapshots/x/ggml-model-ud-q2_k_xl.gguf") == ds,
              "resolves DeepSeek UD-Q2_K_XL from file name")
        check(cfg.modelId(forRunningPath: "/tmp/unknown-model.gguf") == nil,
              "unknown model → nil")
        check(cfg.modelId(forRunningPath: "") == nil,
              "empty path → nil")

        // MARK: Display title

        let title = cfg.displayTitle(for: q4)
        check(title.hasPrefix("Model: Muse-Glimmer-30B Q4_K_M"), "title starts with model name")
        check(title.contains("Muse-Glimmer-30B-GGUF"), "title shows repo name")
        check(title.contains("Q4_K_M"), "title shows quant")
        check(cfg.displayTitle(for: "no-colon-id") == "Model: Unknown", "malformed id degrades gracefully")

        // MARK: Switch decisions

        check(switchAction(selected: q4, current: q4, isRunning: true) == .none, "same model while running → none")
        check(switchAction(selected: q4, current: q4, isRunning: false) == .none, "same model while stopped → none")
        check(switchAction(selected: q5, current: q4, isRunning: false) == .start(q5), "stopped + different → start")
        check(switchAction(selected: q5, current: q4, isRunning: true) == .restart(q5), "running + different → restart")

        // MARK: Deterministic ordering

        let sorted = cfg.sortedModelIDs()
        check(sorted == cfg.sortedModelIDs(), "sortedModelIDs is stable")
        check(sorted.count == cfg.models.count, "sortedModelIDs covers every model")
        check(Set(sorted) == Set(cfg.models.keys), "sortedModelIDs contains exactly the configured ids")

        if failures == 0 {
            print("✅ All model logic tests passed")
            exit(0)
        } else {
            print("✗ \(failures) test(s) failed")
            exit(1)
        }
    }
}
