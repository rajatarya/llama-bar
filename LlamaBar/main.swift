import AppKit
import ServiceManagement

private let scriptDir = NSHomeDirectory() + "/code/personal/llama-bar"
private let configPath = NSHomeDirectory() + "/code/personal/llama-bar/models.json"
private let healthURL = "http://127.0.0.1:8080/health"
private let propsURL = "http://127.0.0.1:8080/props"
private let metricsURL = "http://127.0.0.1:8080/metrics"

// MARK: - Model Config

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
}

// MARK: - Helpers

private func sh(_ args: String...) -> String? {
    let t = Process()
    t.launchPath = args[0]; t.arguments = Array(args.dropFirst())
    let p = Pipe(); t.standardOutput = p; t.launch(); t.waitUntilExit()
    return String(data: p.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
}

private func run(_ args: [String]) {
    let t = Process()
    t.launchPath = args[0]; t.arguments = Array(args.dropFirst())
    t.currentDirectoryPath = scriptDir; try? t.run()
}

private func loadConfig() -> ModelsConfig? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)) else { return nil }
    return try? JSONDecoder().decode(ModelsConfig.self, from: data)
}

private func discoverModels() -> [String] {
    guard let output = sh("/bin/bash", "-c", "\(scriptDir)/discover_models.sh") else { return [] }
    // Parse JSON array
    guard let data = output.data(using: .utf8),
          let models = try? JSONDecoder().decode([String].self, from: data) else { return [] }
    return models
}

private func healthy() -> Bool {
    sh("/usr/bin/curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "2", healthURL)?
        .trimmingCharacters(in: .whitespacesAndNewlines) == "200"
}

/// Return the model ID (repo:quant) whose quant string appears in the
/// loaded model filename, or nil if the server isn't serving or the model
/// is not one we know about.
private func runningModelId() -> String? {
    guard let cfg = config,
          let text = sh("/usr/bin/curl", "-s", "--max-time", "2", propsURL),
          let data = text.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let modelPath = json["model_path"] as? String else { return nil }
    let base = (modelPath as NSString).lastPathComponent.lowercased()
    for (id, _) in cfg.models {
        if let quant = id.split(separator: ":").last?.lowercased(),
           base.contains(quant) {
            return id
        }
    }
    return nil
}

private func metric(_ name: String) -> Double? {
    guard let data = sh("/usr/bin/curl", "-s", "--max-time", "2", metricsURL) else { return nil }
    for line in data.components(separatedBy: "\n") {
        if line.hasPrefix(name) {
            if let val = line.split(separator: " ").last { return Double(val) }
        }
    }
    return nil
}

private func fmtDuration(_ secs: TimeInterval) -> String {
    let s = Int(secs)
    if s < 60 { return "\(s)s" }
    let m = s / 60
    if m < 60 { return "\(m)m \(s % 60)s" }
    return "\(m / 60)h \(m % 60)m"
}

private func formatModelDisplay(modelId: String, name: String) -> String {
    // Parse modelId of form repo/model:quant
    let parts = modelId.split(separator: ":", maxSplits: 1)
    guard parts.count == 2 else { return "Model: \(name)" }
    let repoPart = String(parts[0])
    let quant = String(parts[1])
    let repoName = repoPart.split(separator: "/").last.map(String.init) ?? repoPart
    // Show name with repo and quantization for clarity
    return "Model: \(name) • \(repoName) \(quant)"
}

// MARK: - State

enum State {
    case stopped
    case starting(startedAt: Date)
    case running(startedAt: Date)
}

// MARK: - Menu bar

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let item = NSStatusBar.system.statusItem(withLength: 30)
item.button?.font = NSFont.systemFont(ofSize: 14, weight: .bold)
item.button?.toolTip = "LlamaBar"

let menu = NSMenu()
let titleItem = NSMenuItem(title: "LlamaBar", action: nil, keyEquivalent: "")
titleItem.isEnabled = false
let modelItem = NSMenuItem(title: "No models", action: nil, keyEquivalent: "")
modelItem.isEnabled = false
let stateItem = NSMenuItem(title: "Stopped", action: nil, keyEquivalent: "")
stateItem.isEnabled = false
let statsItem = NSMenuItem(title: "-", action: nil, keyEquivalent: "")
statsItem.isEnabled = false
let startItem = NSMenuItem(title: "Start Server", action: nil, keyEquivalent: "")
let stopItem = NSMenuItem(title: "Stop Server", action: nil, keyEquivalent: "")
menu.addItem(titleItem)
menu.addItem(modelItem)
menu.addItem(stateItem)
menu.addItem(statsItem)
menu.addItem(.separator())
menu.addItem(startItem)
menu.addItem(stopItem)
menu.addItem(.separator())
menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
item.menu = menu

var state: State = .stopped
var lastWasRunning = false
var currentModelId: String = ""
var config: ModelsConfig?

func refresh() {
    let ok = healthy()
    
    // Load config if needed
    if config == nil {
        config = loadConfig()
        if let cfg = config, currentModelId.isEmpty {
            currentModelId = cfg.default_model
        }
    }
    
    // Sync to the model actually loaded by llama-server, if it's one of ours
    if ok, let runningId = runningModelId() {
        currentModelId = runningId
    }
    
    // Update model list
    if let cfg = config {
        let modelId = currentModelId
        let modelName = cfg.models[modelId]?.name ?? "Unknown"
        modelItem.title = formatModelDisplay(modelId: modelId, name: modelName)
    }
    
    // Transition detection
    if ok && !lastWasRunning {
        NSSound(named: "Glass")?.play()
    }
    lastWasRunning = ok
    
    // Update state
    switch state {
    case .stopped:
        if ok { state = .running(startedAt: Date()) }
    case .starting(let t0):
        if ok { state = .running(startedAt: Date()) }
        else if Date().timeIntervalSince(t0) > 120 { state = .stopped }
    case .running:
        if !ok { state = .stopped }
    }
    
    // Render
    switch state {
    case .stopped:
        item.button?.title = "○"
        stateItem.title = "Stopped"
        statsItem.title = "-"
        startItem.isEnabled = true
        stopItem.isEnabled = false
    case .starting(let t0):
        item.button?.title = "◐"
        stateItem.title = "Starting up… \(fmtDuration(Date().timeIntervalSince(t0)))"
        statsItem.title = "Loading model…"
        startItem.isEnabled = false
        stopItem.isEnabled = false
    case .running(let t0):
        item.button?.title = "●"
        stateItem.title = "Running · up \(fmtDuration(Date().timeIntervalSince(t0)))"
        if let tps = metric("llamacpp:predicted_tokens_seconds") {
            statsItem.title = String(format: "%.1f tok/s", tps)
        } else {
            statsItem.title = "tok/s: -"
        }
        startItem.isEnabled = false
        stopItem.isEnabled = true
    }
}

class Target: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

let startTarget = Target {
    if let cfg = loadConfig() {
        let modelId = cfg.default_model
        currentModelId = modelId
        run(["/bin/bash", "-c", "\(scriptDir)/start.sh --model \(modelId)"])
    } else {
        run(["/bin/bash", "-c", "\(scriptDir)/start.sh"])
    }
    state = .starting(startedAt: Date())
    refresh()
}
let stopTarget = Target {
    run(["/bin/bash", "-c", "\(scriptDir)/stop.sh"])
    state = .stopped
}
startItem.target = startTarget; startItem.action = #selector(Target.run)
stopItem.target = stopTarget; stopItem.action = #selector(Target.run)

let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in refresh() }
timer.tolerance = 1
RunLoop.current.add(timer, forMode: .common)

refresh()

// Auto-start the default model on launch if the server is down
if !healthy() {
    startTarget.run()
}

try? SMAppService.mainApp.register()

app.run()
