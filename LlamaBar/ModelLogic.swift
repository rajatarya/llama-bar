// Pure, AppKit-free model logic shared by the menu bar app and its tests.
// Compiles standalone:  swiftc -o /tmp/x LlamaBar/ModelLogic.swift tests/test_model_logic.swift

import Foundation

// MARK: - Model config

/// One entry of models.json. Unknown keys (draft_model, temp, …) are ignored.
struct ModelConfig: Codable {
    let name: String
    let ctx_size: Int
    let ngl: Int
    let batch_size: Int
    let ubatch_size: Int
    let needs_proxy: Bool
    let proxy_injection: String?
    let description: String?
}

struct ModelsConfig: Codable {
    let default_model: String
    let models: [String: ModelConfig]

    static func load(from path: String) -> ModelsConfig? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(ModelsConfig.self, from: data)
    }

    /// Deterministic menu order: by display name, ties broken by id.
    func sortedModelIDs() -> [String] {
        models.keys.sorted { a, b in
            let na = models[a]?.name ?? a, nb = models[b]?.name ?? b
            if na != nb { return na.localizedCaseInsensitiveCompare(nb) == .orderedAscending }
            return a < b
        }
    }

    /// Match a llama-server model_path to one of our configured ids by quant
    /// (e.g. …/ggml-model-q4_k_m.gguf → bartowski/…:Q4_K_M). nil if unknown.
    func modelId(forRunningPath path: String) -> String? {
        let base = (path as NSString).lastPathComponent.lowercased()
        for id in sortedModelIDs() {
            if let quant = id.split(separator: ":").last?.lowercased(),
               base.contains(quant) {
                return id
            }
        }
        return nil
    }

    /// "Model: Muse-Glimmer-30B Q4_K_M • bartowski Q4_K_M"
    func displayTitle(for modelId: String) -> String {
        let name = models[modelId]?.name ?? "Unknown"
        let parts = modelId.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return "Model: \(name)" }
        let repo = String(parts[0])
        let repoName = repo.split(separator: "/").last.map(String.init) ?? repo
        return "Model: \(name) • \(repoName) \(parts[1])"
    }
}

/// Parse the JSON array emitted by discover_models.sh; anything invalid → empty.
func parseDiscoveredModels(_ json: String) -> Set<String> {
    guard let data = json.data(using: .utf8),
          let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
    return Set(list)
}

// MARK: - Switching decision

/// What selecting a model should do, given the server state.
enum SwitchAction: Equatable {
    case none            // already on the selected model
    case start(String)   // server down → launch it
    case restart(String) // server up → stop, then launch it
}

func switchAction(selected: String, current: String, isRunning: Bool) -> SwitchAction {
    if selected == current { return .none }
    return isRunning ? .restart(selected) : .start(selected)
}
