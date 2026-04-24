import AppKit
import WebKit

class StatusBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel?
    private var webView: WKWebView?
    private var pollingTimer: Timer?
    private var clickOutsideMonitor: Any?

    // Thresholds for status-bar icon alert (%)
    private let cpuAlertThreshold:  Double = 80
    private let memAlertThreshold:  Double = 80
    private let gpuAlertThreshold:  Double = 80
    private let diskAlertThreshold: Double = 85

    // Live-metrics rotation (menu-toggle preference)
    private let showLiveMetricsKey = "showLiveMetrics"
    private let rotationSeconds    = 3   // one metric every N polling ticks
    private var tickCount          = 0
    private var metricIndex        = 0
    private let pipGreen           = NSColor(srgbRed: 0.22, green: 1.0, blue: 0.08, alpha: 1.0)

    private var showLiveMetrics: Bool {
        get { UserDefaults.standard.bool(forKey: showLiveMetricsKey) }
        set { UserDefaults.standard.set(newValue, forKey: showLiveMetricsKey) }
    }

    private enum MetricKind { case cpu, memory, gpu, disk }

    override init() {
        super.init()
        setupStatusItem()
        startPolling()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.attributedTitle = iconTitle(alert: false)
        button.target = self
        button.action = #selector(handleStatusClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func handleStatusClick() {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isSecondary {
            showStatusMenu()
        } else {
            togglePanel()
        }
    }

    private func showStatusMenu() {
        guard let button = statusItem.button else { return }
        if panel?.isVisible == true { closePanel() }

        let menu = NSMenu()

        let toggle = NSMenuItem(
            title: "Show Live Metrics",
            action: #selector(toggleLiveMetrics),
            keyEquivalent: ""
        )
        toggle.target = self
        toggle.state  = showLiveMetrics ? .on : .off
        menu.addItem(toggle)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Free Mac Monitor", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.frame.height + 4),
                   in: button)
    }

    @objc private func toggleLiveMetrics() {
        showLiveMetrics.toggle()
        // Reset rotation so the user sees a fresh cycle starting at CPU.
        tickCount   = 0
        metricIndex = 0
        renderStatusBar(SystemMetrics.snapshot())
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func iconTitle(alert: Bool) -> NSAttributedString {
        let color: NSColor = alert
            ? .systemRed
            : NSColor(srgbRed: 0.22, green: 1.0, blue: 0.08, alpha: 1.0)
        return NSAttributedString(string: ">>", attributes: [
            .foregroundColor: color,
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        ])
    }

    // MARK: - Panel toggle

    @objc private func togglePanel() {
        if let p = panel, p.isVisible {
            closePanel()
        } else {
            openPanel()
        }
    }

    private func openPanel() {
        if panel == nil { buildPanel() }
        guard let p = panel else { return }

        // Position directly below the status bar button
        if let btn = statusItem.button, let btnWindow = btn.window {
            let btnScreenRect = btnWindow.convertToScreen(btn.frame)
            let pw: CGFloat = 320
            let ph: CGFloat = 400
            let x = (btnScreenRect.midX - pw / 2).rounded()
            let y = (btnScreenRect.minY - ph).rounded()
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }

        p.makeKeyAndOrderFront(nil)
        installClickOutsideMonitor()
        tick()  // immediate first data push when panel opens
    }

    private func closePanel() {
        removeClickOutsideMonitor()
        panel?.orderOut(nil)
    }

    // Global monitor fires for mouse-downs in OTHER apps/windows — clicks on our own
    // status-bar button and inside the panel are delivered locally and never reach it,
    // so we can safely close on any global click without re-toggle races.
    private func installClickOutsideMonitor() {
        guard clickOutsideMonitor == nil else { return }
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.closePanel()
        }
    }

    private func removeClickOutsideMonitor() {
        if let m = clickOutsideMonitor {
            NSEvent.removeMonitor(m)
            clickOutsideMonitor = nil
        }
    }

    // MARK: - Panel construction

    private func buildPanel() {
        let frame = NSRect(x: 0, y: 0, width: 320, height: 400)

        let p = NSPanel(
            contentRect: frame,
            styleMask:   [.nonactivatingPanel, .borderless],
            backing:     .buffered,
            defer:       false
        )
        p.isOpaque                 = true
        p.backgroundColor          = NSColor(srgbRed: 0.04, green: 0.06, blue: 0.04, alpha: 1)
        p.level                    = .statusBar
        p.collectionBehavior       = [.canJoinAllSpaces, .transient]
        p.isFloatingPanel          = true
        p.hasShadow                = true
        p.isReleasedWhenClosed     = false

        // Round the corners slightly so the panel sits comfortably under the menu bar
        if let cv = p.contentView {
            cv.wantsLayer           = true
            cv.layer?.cornerRadius  = 8
            cv.layer?.masksToBounds = true
        }

        let config = WKWebViewConfiguration()
        let wv = WKWebView(frame: frame, configuration: config)
        wv.autoresizingMask = [.width, .height]

        p.contentView?.addSubview(wv)
        webView = wv
        panel   = p

        loadWebContent()
    }

    private func loadWebContent() {
        guard let wv = webView else { return }

        // Resources live in MacDash.app/Contents/Resources/ after build.sh runs.
        // During swift run / swift build, fall back to the source tree.
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "index", withExtension: "html"),
            sourceTreeResourceURL()
        ]

        for candidate in candidates {
            guard let url = candidate, FileManager.default.fileExists(atPath: url.path) else { continue }
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            return
        }

        // Last-resort inline fallback
        wv.loadHTMLString(
            "<html><body style='background:#0a0f0a;color:#39ff14;font-family:monospace;padding:16px'>" +
            "<p>MacDash — resource files not found.<br>Run ./build.sh first.</p></body></html>",
            baseURL: nil
        )
    }

    // Resolve Sources/MacDash/Resources/index.html relative to the binary's location
    private func sourceTreeResourceURL() -> URL? {
        // Walk up from binary until we find Package.swift, then descend into source resources
        var dir = URL(fileURLWithPath: Bundle.main.executablePath ?? "")
        for _ in 0..<8 {
            dir = dir.deletingLastPathComponent()
            let pkg = dir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: pkg.path) {
                return dir.appendingPathComponent("Sources/FreeMacMonitor/Resources/index.html")
            }
        }
        return nil
    }

    // MARK: - Unified polling (always-on, 1 Hz)
    // Single timer runs whether or not the panel is open so the icon reflects
    // current alert state at all times without requiring the panel to be visible.

    private func startPolling() {
        tick()  // immediate first sample
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(pollingTimer!, forMode: .common)
    }

    private func tick() {
        let snap = SystemMetrics.snapshot()

        tickCount += 1
        if tickCount >= rotationSeconds {
            tickCount = 0
            metricIndex &+= 1
        }

        renderStatusBar(snap)

        guard let p = panel, p.isVisible else { return }
        pushMetricsToWebView(snap)
    }

    // Dispatches to either the `>>` icon or rotating live-metric text.
    // When any threshold is breached we lock rotation to just the alerting
    // metrics so the overloaded one is always visible within ≤ rotationSeconds.
    private func renderStatusBar(_ snap: MetricsSnapshot) {
        let alerting = alertingMetrics(snap)
        let isAlert  = !alerting.isEmpty

        guard showLiveMetrics else {
            statusItem.button?.attributedTitle = iconTitle(alert: isAlert)
            return
        }

        let pool = isAlert ? alerting : availableMetrics(snap)
        guard !pool.isEmpty else {
            statusItem.button?.attributedTitle = iconTitle(alert: false)
            return
        }

        let kind  = pool[abs(metricIndex) % pool.count]
        let text  = formatMetric(kind, snap: snap)
        let color: NSColor = isAlert ? .systemRed : pipGreen
        statusItem.button?.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: color,
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            ]
        )
    }

    private func availableMetrics(_ snap: MetricsSnapshot) -> [MetricKind] {
        var m: [MetricKind] = [.cpu, .memory]
        if snap.gpuUsage >= 0 { m.append(.gpu) }
        m.append(.disk)
        return m
    }

    private func alertingMetrics(_ snap: MetricsSnapshot) -> [MetricKind] {
        var a: [MetricKind] = []
        if snap.cpu > cpuAlertThreshold { a.append(.cpu) }
        if snap.memory > memAlertThreshold { a.append(.memory) }
        if snap.gpuUsage >= 0 && snap.gpuUsage > gpuAlertThreshold { a.append(.gpu) }
        if snap.diskPercent > diskAlertThreshold { a.append(.disk) }
        return a
    }

    private func formatMetric(_ kind: MetricKind, snap: MetricsSnapshot) -> String {
        let label: String
        let value: Double
        switch kind {
        case .cpu:    label = "CPU"; value = snap.cpu
        case .memory: label = "MEM"; value = snap.memory
        case .gpu:    label = "GPU"; value = snap.gpuUsage
        case .disk:   label = "DSK"; value = snap.diskPercent
        }
        let pct = String(format: "%2.0f", max(0, min(100, value)))
        return "\(label) \(pct)%"
    }

    private func pushMetricsToWebView(_ snap: MetricsSnapshot) {
        guard let data   = try? JSONEncoder().encode(snap),
              let jsBody = String(data: data, encoding: .utf8) else { return }
        let js = "if(typeof window.updateMetrics==='function'){window.updateMetrics(\(jsBody));}"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    deinit {
        pollingTimer?.invalidate()
        removeClickOutsideMonitor()
    }
}
