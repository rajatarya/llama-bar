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

        // Config entries are tuning overrides only; all fields optional except name.
        for (id, model) in cfg.models {
            check(!model.name.isEmpty, "\(id) has a name")
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

        let candidates = [q4, q5, bf16, ds, "ggml-org/gemma-3-1b-it-GGUF:Q4_K_M"]
        check(cfg.modelId(forRunningPath: "/models--bartowski--Muse-Glimmer-30B-GGUF/snapshots/x/ggml-model-q4_k_m.gguf", candidates: candidates) == q4,
              "resolves Q4_K_M from file name")
        check(cfg.modelId(forRunningPath: "/models--bartowski--Muse-Glimmer-30B-GGUF/snapshots/x/ggml-model-q5_k_m.gguf", candidates: candidates) == q5,
              "resolves Q5_K_M from file name")
        check(cfg.modelId(forRunningPath: "/models--unsloth--Muse-Glimmer-30B-GGUF/snapshots/x/ggml-model-bf16.gguf", candidates: candidates) == bf16,
              "resolves BF16 from file name")
        check(cfg.modelId(forRunningPath: "/models--unsloth--DeepSeek-V4-Flash-0731-GGUF/snapshots/x/ggml-model-ud-q2_k_xl.gguf", candidates: candidates) == ds,
              "resolves DeepSeek UD-Q2_K_XL from file name")
        check(cfg.modelId(forRunningPath: "/tmp/unknown-model.gguf", candidates: candidates) == nil,
              "unknown model → nil")
        check(cfg.modelId(forRunningPath: "", candidates: candidates) == nil,
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

        // MARK: Discovery-driven menu list

        let discovered = ["zzz/Tiny-GGUF:Q4_K_M", q4, "ggml-org/gemma-3-1b-it-GGUF:Q8_0"]
        let menu = cfg.menuModelIDs(discovered: discovered)
        check(menu.count == discovered.count, "menu covers every discovered model")
        check(Set(menu) == Set(discovered), "menu contains exactly the discovered ids")
        check(cfg.menuModelIDs(discovered: [q4]).first == q4, "single discovered id survives")
        check(cfg.menuModelIDs(discovered: []).isEmpty, "empty discovery → empty menu")
        // Configured models that are NOT cached stay hidden.
        check(!menu.contains("vcruz305/DeepSeek-V4.1-Flash-GGUF:Q2_K"), "uncached config-only model hidden")

        if failures == 0 {
            print("✅ All model logic tests passed")
            exit(0)
        } else {
            print("✗ \(failures) test(s) failed")
            exit(1)
        }
    }
}
