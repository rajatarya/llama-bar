// Foundation-only process runner shared by the menu bar app and its tests.
// Compile standalone:  swiftc -o /tmp/x LlamaBar/Shell.swift LlamaBar/ModelLogic.swift tests/test_model_logic.swift

import Foundation

/// Run a command and return its stdout, or nil if it cannot launch or runs
/// past `timeout` (it is then killed).
///
/// Stdout is drained while the process runs: waiting for exit before reading
/// deadlocks as soon as the output fills the 64 KB pipe buffer (curl blocks
/// writing a large /metrics body and never exits). Waits on semaphores, never
/// on the run loop, so call it from a background queue, not the main thread.
func runCapturing(_ args: [String], timeout: TimeInterval) -> String? {
    guard let exe = args.first else { return nil }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: exe)
    task.arguments = Array(args.dropFirst())
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    let exited = DispatchSemaphore(value: 0)
    task.terminationHandler = { _ in exited.signal() }
    do { try task.run() } catch { return nil }

    var output = Data()
    let drained = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        output = pipe.fileHandleForReading.readDataToEndOfFile()
        drained.signal()
    }

    if exited.wait(timeout: .now() + timeout) == .timedOut {
        task.terminate()
        if exited.wait(timeout: .now() + 1) == .timedOut {
            kill(task.processIdentifier, SIGKILL)
        }
        return nil
    }
    // EOF follows exit unless a grandchild inherited stdout; don't wait on that.
    guard drained.wait(timeout: .now() + 1) == .success else { return nil }
    return String(data: output, encoding: .utf8)
}
