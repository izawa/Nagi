import Foundation
import os

/// One JSON object per line on stdout. Apps are launched with `open --stdout <file>`,
/// so the agent reads the file after the run.
///
/// `t` is `ProcessInfo.systemUptime` (monotonic and shared by all processes), so the
/// Harness and Fixture logs can be merged by time.
public enum SpikeLog {
    /// Also writes every line to the unified log when set (S10: a login launch has no --stdout).
    /// Set once at startup, before the first line.
    nonisolated(unsafe) public static var systemLog: Logger?

    public static func emit(_ event: String, _ fields: [String: any Sendable] = [:]) {
        var object: [String: Any] = fields
        object["event"] = event
        object["t"] = (ProcessInfo.processInfo.systemUptime * 1000).rounded() / 1000
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else {
            print(#"{"event":"log-error","source":"\#(event)"}"#)
            fflush(stdout)
            return
        }
        print(line)
        fflush(stdout)
        systemLog?.notice("\(line, privacy: .public)")
    }

    /// The first line of every run: what was running, where, and how it was built.
    public static func header(_ extra: [String: any Sendable] = [:]) {
        let info = Bundle.main.infoDictionary ?? [:]
        var fields: [String: any Sendable] = [
            "bundleID": Bundle.main.bundleIdentifier ?? "<none>",
            "bundlePath": Bundle.main.bundlePath,
            "pid": Int(getpid()),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "sandboxed": ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil,
            "arguments": Array(CommandLine.arguments.dropFirst()),
            "build": info["CFBundleVersion"] as? String ?? "?",
            "wall": ISO8601DateFormatter().string(from: Date()),
        ]
        fields.merge(extra) { _, new in new }
        emit("header", fields)
    }
}
