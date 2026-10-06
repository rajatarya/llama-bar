import AppKit
import ServiceManagement

private let scriptDir = NSHomeDirectory() + "/code/personal/llama-bar"
private let configPath = scriptDir + "/models.json"
private let healthURL = "http://127.0.0.1:8080/health"
private let propsURL = "http://127.0.0.1:8080/props"
private let metricsURL = "http://127.0.0.1:8080/metrics"
/// How long a launch may take before the menu gives up on it (start.sh's own limit).
private let startTimeout: TimeInterval = 900

// MARK: - Server I/O (pollQueue only, never the main thread)

private func curl(_ url: String) -> String? {
    runCapturing(["/usr/bin/curl", "-s", "--max-time", "2", url], timeout: 5)
}

private func healthy() -> Bool {
    runCapturing(["/usr/bin/curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "2", healthURL],
                 timeout: 5)?.trimmingCharacters(in: .whitespacesAndNewlines) == "200"
}

/// model_path from a server JSON endpoint, or nil.
private func modelPath(from url: String) -> String? {
    guard let text = curl(url),
          let data = text.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return json["model_path"] as? String
}

/// Model IDs available to launch (HF cache + MTPLX packs), via discover_models.sh.
/// It spawns llama-server --cache-list, so it runs only on demand; nil on failure.
private func discoverModels() -> [String]? {
    guard let out = runCapturing(["/bin/bash", "-c", "\(scriptDir)/discover_models.sh"], timeout: 60) else { return nil }
    return Array(parseDiscoveredModels(out)).sorted()
}

/// Launch a script without waiting: start.sh/stop.sh outlive the click.
private func run(_ args: [String]) {
    let t = Process()
    t.executableURL = URL(fileURLWithPath: args[0]); t.arguments = Array(args.dropFirst())
    t.currentDirectoryURL = URL(fileURLWithPath: scriptDir)
    try? t.run()
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
    /// target: the model being launched ("" = start.sh's default).
    case starting(startedAt: Date, target: String)
    case running(startedAt: Date)

    var isStarting: Bool { if case .starting = self { return true }; return false }
}

/// What one poll learned about the server, gathered on pollQueue.
struct Snapshot {
    let healthy: Bool
    let metrics: String?       // /metrics body
    let modelPath: String?     // loaded model: /props (llama-server) or /health (MTPLX)
    let discovered: [String]?  // set when this poll re-scanned the model cache
}

// MARK: - Menu bar

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
item.button?.font = NSFont.menuBarFont(ofSize: 0)
item.button?.title = "○"
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

// Everything below is main-thread state; pollQueue only reads the server.
var state: State = .stopped
var lastWasRunning = false
/// The selected model: what the server runs, or what Start would launch.
var currentModelId = ""
/// The model the server reported on the last poll (nil = down or unresolved).
var runningId: String?
var runningPath: String?
var config: ModelsConfig?
var configModified: Date?
var discovered: [String] = []
var modelSubmenuFingerprint = ""
// NSMenuItem.target is weak, so keep strong refs to keep menu actions alive.
var modelTargets: [String: Target] = [:]
// Busy-detection state: last /metrics poll identity + spinner frame index.
var lastPollKey: String?
var spinPhase = 0
var tokensPerSecond: Double?
// Polling: one poll at a time; the first poll scans the cache and may auto-start.
let pollQueue = DispatchQueue(label: "com.rajatarya.llamabar.poll", qos: .utility)
var pollInFlight = false
var rescanPending = true
var firstPoll = true

/// Load models.json when it changes, so name/short_name edits show without a
/// relaunch. A broken edit keeps the last good config.
func reloadConfigIfChanged() {
    let modified = (try? FileManager.default.attributesOfItem(atPath: configPath))?[.modificationDate] as? Date
    guard config == nil || modified != configModified else { return }
    configModified = modified
    guard let cfg = ModelsConfig.load(from: configPath) else { return }
    config = cfg
    if currentModelId.isEmpty { currentModelId = cfg.default_model }
    modelSubmenuFingerprint = ""
}

/// Gather server state on pollQueue, then apply it on the main thread. The
/// main thread never waits on curl or a script, so a slow or wedged server
/// cannot freeze the menu bar, and at most one poll is in flight.
func schedulePoll() {
    guard !pollInFlight else { return }
    pollInFlight = true
    let scan = rescanPending
    rescanPending = false
    pollQueue.async {
        let ok = healthy()
        let snapshot = Snapshot(
            healthy: ok,
            metrics: ok ? curl(metricsURL) : nil,
            modelPath: ok ? (modelPath(from: propsURL) ?? modelPath(from: healthURL)) : nil,
            discovered: scan ? discoverModels() : nil)
        DispatchQueue.main.async {
            pollInFlight = false
            apply(snapshot)
        }
    }
}

func apply(_ snap: Snapshot) {
    reloadConfigIfChanged()
    if let ids = snap.discovered { discovered = ids }
    if snap.healthy && !lastWasRunning {
        NSSound(named: "Glass")?.play()
        rescanPending = true  // pick up models downloaded while it was down
    }
    lastWasRunning = snap.healthy

    runningPath = snap.modelPath
    runningId = snap.modelPath.flatMap { path in config?.modelId(forRunningPath: path, candidates: discovered) }

    if let body = snap.metrics {
        let activity = parseServerActivity(body)
        let busy = detectGenerationBusy(activity: activity, previousKey: lastPollKey)
        lastPollKey = busyPollKey(activity: activity, body: body)
        spinPhase = busy ? spinPhase % 4 + 1 : 0  // 1…4 = spinner frame, 0 = idle
        tokensPerSecond = parseDecodeTokensPerSecond(body)
    } else {
        lastPollKey = nil
        spinPhase = 0
        tokensPerSecond = nil
    }

    switch state {
    case .stopped:
        if snap.healthy { state = .running(startedAt: Date()) }
    case .starting(let t0, let target):
        // Mid-switch the old model still answers until stop.sh lands: wait for the target.
        if snap.healthy && (target.isEmpty || runningId == nil || runningId == target) {
            state = .running(startedAt: Date())
        } else if Date().timeIntervalSince(t0) > startTimeout {
            state = .stopped
        }
    case .running:
        if !snap.healthy { state = .stopped }
    }
    if case .running = state, let id = runningId { currentModelId = id }

    // Auto-start the selected model when the app launches and the server is down.
    if firstPoll {
        firstPoll = false
        if !snap.healthy, case .stopped = state { startSelected() }
    }
    render()
}

/// Rebuild the Models submenu only when the selection or available set changed,
/// so the 2s refresh loop never flickers an open menu.
func rebuildModelSubmenuIfNeeded() {
    let ids = config?.menuModelIDs(discovered: discovered) ?? []
    let fingerprint = "\(currentModelId)|\(ids)"
    guard fingerprint != modelSubmenuFingerprint else { return }
    modelSubmenuFingerprint = fingerprint
    modelMenu.removeAllItems()
    modelTargets.removeAll()
    guard config != nil || !discovered.isEmpty else { return }
    for id in ids {
        let mi = NSMenuItem(title: config?.models[id]?.name ?? derivedModelName(id), action: nil, keyEquivalent: "")
        mi.toolTip = config?.models[id]?.description ?? id
        if id == currentModelId { mi.state = .on }
        let target = Target { selectModel(id) }
        modelTargets[id] = target
        mi.target = target
        mi.action = #selector(Target.run)
        modelMenu.addItem(mi)
    }
}

/// Menu bar text: status glyph plus the model's compact label.
func setStatus(_ glyph: String, label: String, tooltip: String) {
    let title = label.isEmpty ? glyph : "\(glyph) \(label)"
    if item.button?.title != title { item.button?.title = title }
    item.button?.toolTip = tooltip
}

func render() {
    let cfg = config
    let selectedTitle = cfg?.displayTitle(for: currentModelId) ?? "No models"
    rebuildModelSubmenuIfNeeded()
    // Switching mid-boot is a race, so disable model items while starting.
    for mi in modelMenu.items { mi.isEnabled = !state.isStarting }

    switch state {
    case .stopped:
        setStatus("○", label: "", tooltip: "LlamaBar: stopped")
        modelItem.title = selectedTitle
        stateItem.title = "Stopped"
        statsItem.title = "-"
        startItem.isEnabled = true
        stopItem.isEnabled = false
    case .starting(let t0, let target):
        let id = target.isEmpty ? currentModelId : target
        setStatus("◐", label: cfg?.menuBarLabel(for: id) ?? "", tooltip: "LlamaBar: starting \(id)")
        modelItem.title = cfg?.displayTitle(for: id) ?? selectedTitle
        stateItem.title = "Starting up… \(fmtDuration(Date().timeIntervalSince(t0)))"
        statsItem.title = "Loading model…"
        startItem.isEnabled = false
        stopItem.isEnabled = false
    case .running(let t0):
        let busy = spinPhase > 0
        let glyph = busy ? ["◐", "◓", "◑", "◒"][spinPhase - 1] : "●"
        if let id = runningId, let cfg {
            setStatus(glyph, label: cfg.menuBarLabel(for: id), tooltip: cfg.displayTitle(for: id))
            modelItem.title = cfg.displayTitle(for: id)
        } else {
            // Serving something LlamaBar didn't launch (or not in the cache): show its file.
            let file = runningPath.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? "?"
            let label = file.count > menuBarLabelMaxLength ? String(file.prefix(menuBarLabelMaxLength - 1)) + "…" : file
            setStatus(glyph, label: label, tooltip: runningPath ?? "LlamaBar: model unknown")
            modelItem.title = "Model: \(file)"
        }
        stateItem.title = (busy ? "Generating" : "Running") + " · up \(fmtDuration(Date().timeIntervalSince(t0)))"
        statsItem.title = tokensPerSecond.map { String(format: "%.1f tok/s", $0) } ?? "tok/s: -"
        startItem.isEnabled = false
        stopItem.isEnabled = true
    }
}

/// Start the given model via start.sh (async) and enter the starting state.
func launchModel(_ modelId: String) {
    run(["/bin/bash", "-c", "\(scriptDir)/start.sh --model \(modelId)"])
    state = .starting(startedAt: Date(), target: modelId)
    render()
    schedulePoll()
}

/// Launch the selected model, or start.sh's default if nothing is selected.
func startSelected() {
    if currentModelId.isEmpty {
        run(["/bin/bash", "-c", "\(scriptDir)/start.sh"])
        state = .starting(startedAt: Date(), target: "")
        render()
        schedulePoll()
    } else {
        launchModel(currentModelId)
    }
}

/// Apply a selection from the Models submenu.
func selectModel(_ modelId: String) {
    guard !state.isStarting else { return } // switching mid-boot is a race
    switch switchAction(selected: modelId, current: currentModelId, isRunning: lastWasRunning) {
    case .none:
        currentModelId = modelId
        render()
    case .start(let id):
        currentModelId = id
        launchModel(id)
    case .restart(let id):
        currentModelId = id
        // One shell runs stop+start so stop fully finishes before start's PID check.
        run(["/bin/bash", "-c", "\(scriptDir)/stop.sh; \(scriptDir)/start.sh --model \(id)"])
        state = .starting(startedAt: Date(), target: id)
        render()
        schedulePoll()
    }
}

class Target: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

let startTarget = Target { startSelected() }
let stopTarget = Target {
    run(["/bin/bash", "-c", "\(scriptDir)/stop.sh"])
    state = .stopped
    render()
}
startItem.target = startTarget; startItem.action = #selector(Target.run)
stopItem.target = stopTarget; stopItem.action = #selector(Target.run)

let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in schedulePoll() }
timer.tolerance = 1
RunLoop.current.add(timer, forMode: .common)

try? SMAppService.mainApp.register()

// The first poll runs in the background; the menu bar is live immediately.
schedulePoll()
app.run()
