import Foundation

// Once-a-day (plus on-demand) check against GitHub Releases. No Sparkle, no
// bundled feed — the release pipeline already publishes tagged releases, so
// the `releases/latest` endpoint is the single source of truth.
enum UpdateChecker {
    enum CheckResult {
        case upToDate
        case updateAvailable(version: String, url: String)
        case failed(String)
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private static let latestReleaseURL =
        URL(string: "https://api.github.com/repos/pekinlcc/FreeMacMonitor/releases/latest")!

    /// Completion is always delivered on the main queue.
    static func check(completion: @escaping (CheckResult) -> Void) {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, _, error in
            let result: CheckResult
            if let error = error {
                result = .failed(error.localizedDescription)
            } else if let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag  = json["tag_name"] as? String {
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let url = (json["html_url"] as? String)
                       ?? "https://github.com/pekinlcc/FreeMacMonitor/releases/latest"
                result = isNewer(latest, than: currentVersion)
                    ? .updateAvailable(version: latest, url: url)
                    : .upToDate
            } else {
                result = .failed("Unexpected response from GitHub.")
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    // Compare dotted numeric versions ("1.10.0" > "1.9.2"); missing
    // components count as 0, non-numeric components as 0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
