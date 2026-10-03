// Pure, AppKit-free model logic shared by the menu bar app and its tests.
// Compiles standalone:  swiftc -o /tmp/x LlamaBar/ModelLogic.swift tests/test_model_logic.swift

import Foundation

// MARK: - Model config

/// One entry of models.json. Unknown keys (draft_model, temp, …) are ignored.
/// Only name is required: entries are tuning overrides, and MTPLX entries have
/// no llama.cpp tuning at all.
struct ModelConfig: Codable {
    let name: String
    let backend: String?     // "llamacpp" (default) or "mtplx"
    let ctx_size: Int?
    let ngl: Int?
    let batch_size: Int?
    let ubatch_size: Int?
    let needs_proxy: Bool?
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

    /// Menu order: every discovered model first (tuning overrides are just
    /// decoration); config-only models stay hidden until they're cached.
    func menuModelIDs(discovered: [String]) -> [String] {
        discovered.sorted { a, b in
            let na = models[a]?.name ?? a, nb = models[b]?.name ?? b
            if na != nb { return na.localizedCaseInsensitiveCompare(nb) == .orderedAscending }
            return a < b
        }
    }


    /// Match a server's model_path to one of the available ids. MTPLX reports
    /// its pack directory (…/owner--repo), matched exactly; llama-server
    /// reports a GGUF, matched by quant (…/ggml-model-q4_k_m.gguf →
    /// bartowski/…:Q4_K_M). nil if unknown.
    func modelId(forRunningPath path: String, candidates: [String]) -> String? {
        let base = (path as NSString).lastPathComponent.lowercased()
        let ids = menuModelIDs(discovered: candidates)
        let isMtplx = { (id: String) in id.hasSuffix(":MTPLX") }
        for id in ids where isMtplx(id) {
            let repo = id.dropLast(":MTPLX".count)
            if base == repo.replacingOccurrences(of: "/", with: "--").lowercased() { return id }
        }
        // Longest id first so ":Q4_K_M" never steals a ":Q4_K_M_XL" path.
        for id in ids.filter({ !isMtplx($0) }).sorted(by: { $0.count > $1.count }) {
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

// MARK: - Throughput

/// Generation tok/s from a server's /metrics body: llama-server's Prometheus
/// gauge, or MTPLX's JSON (latest request's decode speed). nil if absent.
func parseDecodeTokensPerSecond(_ body: String) -> Double? {
    let gauge = "llamacpp:predicted_tokens_seconds"
    for line in body.components(separatedBy: "\n") where line.hasPrefix(gauge) {
        if let val = line.split(separator: " ").last { return Double(val) }
    }
    guard let data = body.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let latest = json["latest"] as? [String: Any] else { return nil }
    return (latest["display_decode_tok_s"] ?? latest["decode_tok_s"]) as? Double
}

// MARK: - Busy detection

/// Activity signal read from one /metrics fetch.
struct ServerActivity: Equatable {
    var processing: Int?      // llama.cpp:requests_processing gauge
    var predictedTotal: Int?  // llama.cpp:tokens_predicted_total counter
    var requestKey: String?   // MTPLX latest request identity
}

/// Extract the activity signal from a /metrics body (Prometheus text or MTPLX
/// JSON). MTPLX's `latest` block is a stale snapshot of the last completed
/// request, so identity = request_id + completion_tokens + decode_elapsed_s.
func parseServerActivity(_ body: String) -> ServerActivity {
    var a = ServerActivity()
    for line in body.components(separatedBy: "\n") {
        if line.hasPrefix("llamacpp:requests_processing ") {
            a.processing = Int(line.split(separator: " ").last ?? "")
        } else if line.hasPrefix("llamacpp:tokens_predicted_total ") {
            a.predictedTotal = Int(line.split(separator: " ").last ?? "")
        }
    }
    if a.processing == nil && a.predictedTotal == nil,
       let data = body.data(using: .utf8),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let latest = json["latest"] as? [String: Any] {
        let id = latest["request_id"] as? String ?? "?"
        let tok = latest["completion_tokens"] ?? "0"
        let dec = latest["decode_elapsed_s"] ?? "0"
        a.requestKey = "\(id):\(tok):\(dec)"
    }
    return a
}

/// True while a generation is in flight. llama.cpp: explicit processing gauge,
/// else predicted-token counter growth against the previous poll's "t<count>"
/// key. MTPLX: the latest-request identity changed since the last poll.
/// `previousKey` nil = first poll → never busy.
func detectGenerationBusy(activity: ServerActivity, previousKey: String?) -> Bool {
    guard let previousKey else { return false }
    if let p = activity.processing { return p > 0 }
    if let t = activity.predictedTotal {
        return previousKey != "t\(t)"
    }
    if let k = activity.requestKey { return k != previousKey }
    return false
}

/// Poll-state key for one /metrics body: the MTPLX request identity, else the
/// llama.cpp predicted-token count, else the raw body (identical bodies across
/// polls — a stale MTPLX snapshot — read as idle).
func busyPollKey(activity: ServerActivity, body: String) -> String {
    if let k = activity.requestKey { return k }
    if let t = activity.predictedTotal { return "t\(t)" }
    return body
}

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