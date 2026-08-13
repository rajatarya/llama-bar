import AppKit
import ServiceManagement

private let scriptDir = NSHomeDirectory() + "/code/personal/llama-bar"
private let configPath = NSHomeDirectory() + "/code/personal/llama-bar/models.json"
private let healthURL = "http://127.0.0.1:8080/health"
private let propsURL = "http://127.0.0.1:8080/props"
private let metricsURL = "http://127.0.0.1:8080/metrics"

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

private func healthy() -> Bool {
    sh("/usr/bin/curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "2", healthURL)?
        .trimmingCharacters(in: .whitespacesAndNewlines) == "200"
}

/// The model id llama-server is actually serving (matched by quant from /props), or nil.
private func runningModelId(_ cfg: ModelsConfig) -> String? {
    guard let text = sh("/usr/bin/curl", "-s", "--max-time", "2", propsURL),
          let data = text.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let modelPath = json["model_path"] as? String else { return nil }
    return cfg.modelId(forRunningPath: modelPath)
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

// MARK: - State

enum State {
    case stopped
    case starting(startedAt: Date)
    case running(startedAt: Date)

    var isStarting: Bool { if case .starting = self { return true }; return false }
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
let modelsItem = NSMenuItem(title: "Models", action: nil, keyEquivalent: "")
modelsItem.toolTip = "Switch the running model"
let modelMenu = NSMenu()
modelsItem.submenu = modelMenu
let startItem = NSMenuItem(title: "Start Server", action: nil, keyEquivalent: "")
let stopItem = NSMenuItem(title: "Stop Server", action: nil, keyEquivalent: "")
menu.addItem(titleItem)
menu.addItem(modelItem)
menu.addItem(stateItem)
menu.addItem(statsItem)
menu.addItem(.separator())
menu.addItem(modelsItem)
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
var modelSubmenuFingerprint = ""
// NSMenuItem.target is weak, so keep strong refs to keep menu actions alive.
var modelTargets: [String: Target] = [:]

/// Rebuild the Models submenu only when the selection or config changed, so the
/// 2s refresh loop never flickers an open menu.
func rebuildModelSubmenuIfNeeded() {
    let fingerprint = "\(currentModelId)|\(config == nil)"
    guard fingerprint != modelSubmenuFingerprint else { return }
    modelSubmenuFingerprint = fingerprint
    modelMenu.removeAllItems()
    modelTargets.removeAll()
    guard let cfg = config else { return }
    for id in cfg.sortedModelIDs() {
        let mi = NSMenuItem(title: cfg.models[id]?.name ?? id, action: nil, keyEquivalent: "")
        mi.toolTip = cfg.models[id]?.description
        if id == currentModelId { mi.state = .on }
        let target = Target { selectModel(id) }
        modelTargets[id] = target
        mi.target = target
        mi.action = #selector(Target.run)
        modelMenu.addItem(mi)
    }
}

/// Start the given model via start.sh (async) and enter the starting state.
func launchModel(_ modelId: String) {
    run(["/bin/bash", "-c", "\(scriptDir)/start.sh --model \(modelId)"])
    state = .starting(startedAt: Date())
    refresh()
}

/// Apply a selection from the Models submenu.
func selectModel(_ modelId: String) {
    guard !state.isStarting else { return } // switching mid-boot is a race
    switch switchAction(selected: modelId, current: currentModelId, isRunning: healthy()) {
    case .none:
        currentModelId = modelId
        refresh()
    case .start(let id):
        currentModelId = id
        launchModel(id)
    case .restart(let id):
        currentModelId = id
        // One shell runs stop+start so stop fully finishes before start's PID check.
        run(["/bin/bash", "-c", "\(scriptDir)/stop.sh; \(scriptDir)/start.sh --model \(id)"])
        state = .starting(startedAt: Date())
        refresh()
    }
}

func refresh() {
    let ok = healthy()

    // Load config once; the first load pins the default model as current.
    if config == nil {
        config = ModelsConfig.load(from: configPath)
        if let cfg = config, currentModelId.isEmpty {
            currentModelId = cfg.default_model
        }
    }

    // Sync to the model actually loaded by llama-server, if it's one of ours.
    if ok, let cfg = config, let runningId = runningModelId(cfg) {
        currentModelId = runningId
    }

    if let cfg = config {
        modelItem.title = cfg.displayTitle(for: currentModelId)
        rebuildModelSubmenuIfNeeded()
        // Switching mid-boot is a race, so disable model items while starting.
        let switchingAllowed = !state.isStarting
        for mi in modelMenu.items { mi.isEnabled = switchingAllowed }
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

// Start launches the selected model; falls back to start.sh defaults if no config.
let startTarget = Target {
    let id = currentModelId.isEmpty ? (config?.default_model ?? "") : currentModelId
    if id.isEmpty {
        run(["/bin/bash", "-c", "\(scriptDir)/start.sh"])
        state = .starting(startedAt: Date())
        refresh()
    } else {
        launchModel(id)
    }
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
