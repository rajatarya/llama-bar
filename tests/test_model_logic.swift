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

        // MARK: MTPLX backend

        let fnMtplx = "Youssofal/Qwen3.8-Flash-Next-MTPLX-Optimized-Speed:MTPLX"
        let q27Mtplx = "Youssofal/Qwen3.8-27B-MTPLX-Optimized-Quality:MTPLX"
        let fnGguf = "unsloth/Qwen3.8-Flash-Next-GGUF:IQ4_XS"
        let mixed = [fnMtplx, q27Mtplx, fnGguf, q4]
        // MTPLX has no /props; its /health model_path is the pack directory.
        check(cfg.modelId(forRunningPath: "/Users/x/.mtplx/models/Youssofal--Qwen3.8-Flash-Next-MTPLX-Optimized-Speed", candidates: mixed) == fnMtplx,
              "resolves MTPLX pack from /health model_path")
        check(cfg.modelId(forRunningPath: "/Users/x/.mtplx/models/Youssofal--Qwen3.8-27B-MTPLX-Optimized-Quality/", candidates: mixed) == q27Mtplx,
              "picks the right MTPLX pack (trailing slash ok)")
        check(cfg.modelId(forRunningPath: "/models--unsloth--Qwen3.8-Flash-Next-GGUF/snapshots/x/UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf", candidates: mixed) == fnGguf,
              "GGUF path still resolves to the GGUF id alongside MTPLX ids")
        check(cfg.modelId(forRunningPath: "/Users/x/.mtplx/models/Someone--Unknown-MTPLX-Pack", candidates: mixed) == nil,
              "unknown MTPLX pack → nil (\":MTPLX\" never quant-matches)")
        check(cfg.displayTitle(for: fnMtplx).hasSuffix("MTPLX"), "MTPLX title shows backend tag")

        // Entries only need a name; llama.cpp tuning fields are optional.
        let minimal = #"{"default_model":"a:MTPLX","models":{"a:MTPLX":{"name":"A","backend":"mtplx"}}}"#
        let minCfg = try? JSONDecoder().decode(ModelsConfig.self, from: Data(minimal.utf8))
        check(minCfg?.models["a:MTPLX"]?.backend == "mtplx", "entry with only name + backend decodes")

        // MARK: tok/s parsing (llama.cpp Prometheus text and MTPLX JSON)

        let prom = """
        # HELP llamacpp:predicted_tokens_seconds Average generation throughput in tokens/s.
        # TYPE llamacpp:predicted_tokens_seconds gauge
        llamacpp:predicted_tokens_seconds 42.5
        llamacpp:prompt_tokens_seconds 700
        """
        check(parseDecodeTokensPerSecond(prom) == 42.5, "parses llama.cpp Prometheus tok/s")
        let mtplxMetrics = #"{"latest":{"decode_tok_s":30.0,"display_decode_tok_s":31.5},"recent":[]}"#
        check(parseDecodeTokensPerSecond(mtplxMetrics) == 31.5, "parses MTPLX JSON tok/s")
        check(parseDecodeTokensPerSecond(#"{"latest":null,"recent":[]}"#) == nil, "MTPLX before first request → nil")
        check(parseDecodeTokensPerSecond("garbage") == nil, "garbage metrics → nil")

        if failures == 0 {
            print("✅ All model logic tests passed")
            exit(0)
        } else {
            print("✗ \(failures) test(s) failed")
            exit(1)
        }
    }
}
