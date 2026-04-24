import AppKit
import Foundation

// Abstraction over the three honest ways to run `/usr/sbin/purge` on macOS
// without an Apple Developer cert or a privileged helper:
//
//   .notify       → don't run purge; the caller posts a user notification
//   .autoPassword → `osascript … do shell script "purge" with administrator privileges`
//                    prompts for admin password each time
//   .autoSudoers  → `sudo -n /usr/sbin/purge`, requires a pre-installed sudoers
//                    rule (see README). Falls back to failure if rule absent.
//
// All invocations run on a background queue; the completion is delivered on
// the main queue.  `beforeBytes` / `afterBytes` snapshots let the UI show an
// honest "▼N%" delta (or "▼0" when purge did nothing measurable).
enum AutoReleaseMode: String {
    case off
    case notify
    case autoPassword = "auto-password"
    case autoSudoers  = "auto-sudoers"

    var menuTitle: String {
        switch self {
        case .off:          return "Off"
        case .notify:       return "Notify only (recommended)"
        case .autoPassword: return "Auto-run — prompt password"
        case .autoSudoers:  return "Auto-run — sudoers-free"
        }
    }
}

struct ReleaseResult {
    let beforeBytes: UInt64
    let afterBytes:  UInt64
    let success:     Bool
    let errorMessage: String?

    // Percentage-point drop in pressure (before% − after%), clamped ≥ 0.
    func delta(total: UInt64) -> Double {
        guard total > 0, beforeBytes >= afterBytes else { return 0 }
        return Double(beforeBytes - afterBytes) / Double(total) * 100
    }

    var bytesReleased: UInt64 {
        beforeBytes >= afterBytes ? beforeBytes - afterBytes : 0
    }
}

enum MemoryReleaser {
    // The actual purge call.  Caller chooses the mode; completion fires on main.
    static func release(mode: AutoReleaseMode, completion: @escaping (ReleaseResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let before = SystemMetrics.memoryBreakdown()
            let beforeUsed = before.app + before.wired + before.compressed

            var ok = false
            var err: String? = nil

            switch mode {
            case .off, .notify:
                // Caller shouldn't have called us in these modes, but be safe.
                err = "release suppressed by mode \(mode.rawValue)"
            case .autoPassword:
                (ok, err) = runViaAppleScript()
            case .autoSudoers:
                (ok, err) = runViaSudo()
            }

            // Re-sample *after* purge completes.  Purge on recent macOS typically
            // runs <1s but the VM stats can lag slightly; a small delay makes the
            // delta more honest without blocking the UI.
            Thread.sleep(forTimeInterval: 0.4)
            let after = SystemMetrics.memoryBreakdown()
            let afterUsed = after.app + after.wired + after.compressed

            let result = ReleaseResult(
                beforeBytes: beforeUsed,
                afterBytes:  afterUsed,
                success:     ok,
                errorMessage: err
            )
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - Backends

    private static func runViaAppleScript() -> (Bool, String?) {
        let src = "do shell script \"/usr/sbin/purge\" with administrator privileges"
        var err: NSDictionary?
        let script = NSAppleScript(source: src)
        _ = script?.executeAndReturnError(&err)
        if let err = err {
            let code = err[NSAppleScript.errorNumber] as? Int ?? -1
            // -128 = user cancelled the authentication dialog.
            if code == -128 { return (false, "cancelled") }
            let msg = err[NSAppleScript.errorMessage] as? String ?? "script error \(code)"
            return (false, msg)
        }
        return (true, nil)
    }

    private static func runViaSudo() -> (Bool, String?) {
        let task = Process()
        task.launchPath = "/usr/bin/sudo"
        task.arguments  = ["-n", "/usr/sbin/purge"]      // -n = never prompt
        let errPipe = Pipe()
        task.standardError  = errPipe
        task.standardOutput = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return (false, error.localizedDescription)
        }
        if task.terminationStatus == 0 { return (true, nil) }
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Typical stderr when no NOPASSWD rule exists:
        //   "sudo: a password is required"
        return (false, stderr.isEmpty ? "sudo exited \(task.terminationStatus)" : stderr)
    }
}
