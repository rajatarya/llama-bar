import AppKit
import ServiceManagement

private let scriptDir = NSHomeDirectory() + "/code/personal/llama-server"
private let healthURL = "http://127.0.0.1:8080/health"
private let metricsURL = "http://127.0.0.1:8080/metrics"

// MARK: - Helpers

private func sh(_ args: String...) -> String? {
    let t = Process()
    t.launchPath = args[0]; t.arguments = Array(args.dropFirst())
    let p = Pipe(); t.standardOutput = p; t.launch(); t.waitUntilExit()
    return String(data: p.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
}

private func run(_ script: String) {
    let t = Process()
    t.launchPath = "/bin/bash"; t.arguments = [script]
    t.currentDirectoryPath = scriptDir; try? t.run()
}

private func healthy() -> Bool {
    sh("/usr/bin/curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "2", healthURL)?
        .trimmingCharacters(in: .whitespacesAndNewlines) == "200"
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
}

// MARK: - Menu bar

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let item = NSStatusBar.system.statusItem(withLength: 30)
item.button?.font = NSFont.systemFont(ofSize: 14, weight: .bold)
item.button?.toolTip = "Muse-Glimmer-30B-BF16"

let menu = NSMenu()
let titleItem = NSMenuItem(title: "Muse-Glimmer-30B-BF16", action: nil, keyEquivalent: "")
titleItem.isEnabled = false
let stateItem = NSMenuItem(title: "Stopped", action: nil, keyEquivalent: "")
stateItem.isEnabled = false
let statsItem = NSMenuItem(title: "-", action: nil, keyEquivalent: "")
statsItem.isEnabled = false
let startItem = NSMenuItem(title: "Start Server", action: nil, keyEquivalent: "")
let stopItem = NSMenuItem(title: "Stop Server", action: nil, keyEquivalent: "")
menu.addItem(titleItem)
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

func refresh() {
    let ok = healthy()

    // Transition detection
    if ok && !lastWasRunning {
        NSSound(named: "Glass")?.play()  // ding when model becomes ready
    }
    lastWasRunning = ok

    // Update state
    switch state {
    case .stopped:
        if ok { state = .running(startedAt: Date()) }
    case .starting(let t0):
        if ok { state = .running(startedAt: Date()) }
        else if Date().timeIntervalSince(t0) > 120 { state = .stopped }  // gave up
    case .running(let t0):
        if !ok { state = .stopped }
        else { _ = t0 }
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
    run("start.sh")
    state = .starting(startedAt: Date())
    refresh()
}
let stopTarget = Target {
    run("stop.sh")
    state = .stopped
    refresh()
}
startItem.target = startTarget; startItem.action = #selector(Target.run)
stopItem.target = stopTarget; stopItem.action = #selector(Target.run)

let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in refresh() }
timer.tolerance = 1
RunLoop.current.add(timer, forMode: .common)

// Auto-start on launch
state = .starting(startedAt: Date())
refresh()
run("start.sh")

try? SMAppService.mainApp.register()

app.run()
