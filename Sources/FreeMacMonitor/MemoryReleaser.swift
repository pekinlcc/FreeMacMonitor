import AppKit
import Foundation

// Abstraction over the three honest ways to run `/usr/sbin/purge` on macOS
// without an Apple Developer cert or a privileged helper:
//
//   .notify       → don't run purge; the caller posts a user notification
//   .autoPassword → used only for an explicit “Release now” action; it can
//                    prompt for an admin password, never from the background
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
        case .autoPassword: return "Run manually — prompt password"
        case .autoSudoers:  return "Auto-run — sudoers-free"
        }
    }
}

enum ReleaseOutcome: Equatable {
    case success
    case cancelled          // user dismissed the admin password dialog
    case failure(String)
}

struct ReleaseResult {
    let beforeBytes: UInt64
    let afterBytes:  UInt64
    let outcome:     ReleaseOutcome

    var success: Bool {
        if case .success = outcome { return true }
        return false
    }

    var cancelled: Bool {
        if case .cancelled = outcome { return true }
        return false
    }

    var errorMessage: String? {
        switch outcome {
        case .success:        return nil
        case .cancelled:      return "cancelled"
        case .failure(let m): return m
        }
    }

    // Percentage-point drop in total used (App+Wired+Compressed+Cached) over
    // physical RAM, clamped ≥ 0.  `purge` reclaims file-backed cache, which
    // lives in the Cached bucket — measuring only the pressure buckets here
    // would report "▼0" even after freeing gigabytes.
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

            let outcome: ReleaseOutcome
            switch mode {
            case .off, .notify:
                // Caller shouldn't have called us in these modes, but be safe.
                outcome = .failure("release suppressed by mode \(mode.rawValue)")
            case .autoPassword:
                outcome = runViaAppleScript()
            case .autoSudoers:
                outcome = runViaSudo()
            }

            // Re-sample *after* purge completes.  Purge on recent macOS typically
            // runs <1s but the VM stats can lag slightly; a short delay makes the
            // delta more honest without blocking the UI.  asyncAfter (not
            // Thread.sleep) keeps the GCD worker available in the meantime.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.4) {
                let after = SystemMetrics.memoryBreakdown()
                let result = ReleaseResult(
                    beforeBytes: before.used,
                    afterBytes:  after.used,
                    outcome:     outcome
                )
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    // MARK: - Backends

    private static func runViaAppleScript() -> ReleaseOutcome {
        let src = "do shell script \"/usr/sbin/purge\" with administrator privileges"
        var err: NSDictionary?
        let script = NSAppleScript(source: src)
        _ = script?.executeAndReturnError(&err)
        if let err = err {
            let code = err[NSAppleScript.errorNumber] as? Int ?? -1
            // -128 = user cancelled the authentication dialog.
            if code == -128 { return .cancelled }
            let msg = err[NSAppleScript.errorMessage] as? String ?? "script error \(code)"
            return .failure(msg)
        }
        return .success
    }

    private static func runViaSudo() -> ReleaseOutcome {
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
            return .failure(error.localizedDescription)
        }
        if task.terminationStatus == 0 { return .success }
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Typical stderr when no NOPASSWD rule exists:
        //   "sudo: a password is required"
        return .failure(stderr.isEmpty ? "sudo exited \(task.terminationStatus)" : stderr)
    }
}
