import AppKit
import UserNotifications
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

    // Auto-release: trigger when pressure ≥ 98 for `autoReleaseHoldTicks` consecutive samples.
    // Using (App+Wired+Compressed)/Total (MemoryBreakdown.pressure) avoids false alarms from
    // legitimately-high cache pages.
    private let autoReleaseTriggerPct:  Double = 98
    private let autoReleaseHoldTicks:   Int    = 3      // 3 seconds of sustained pressure
    private let autoReleaseCooldownSec: Double = 60     // don't retrigger for 60s after a run

    // Live-metrics rotation (menu-toggle preference)
    private let showLiveMetricsKey      = "showLiveMetrics"
    private let showMemBreakdownKey     = "showMemoryBreakdown"
    private let autoReleaseModeKey      = "autoReleaseMode"
    private let themeKey                = "theme"
    private let rotationSeconds         = 3
    private var tickCount               = 0
    private var metricIndex             = 0
    private let pipGreen                = NSColor(srgbRed: 0.22, green: 1.0, blue: 0.08, alpha: 1.0)
    private let pipAmber                = NSColor(srgbRed: 1.00, green: 0.82, blue: 0.29, alpha: 1.0)

    // Auto-release / animation runtime state
    private var pressureHighTicks       = 0
    private var lastReleaseAt: Date?
    private var animationFrames: [(String, NSColor)] = []
    private var animationIndex          = 0
    private var animationTimer:  Timer?
    private var isReleasing             = false
    private var lastReleaseResult: (bytes: UInt64, deltaPct: Double, time: Date)?

    private var showLiveMetrics: Bool {
        get { UserDefaults.standard.bool(forKey: showLiveMetricsKey) }
        set { UserDefaults.standard.set(newValue, forKey: showLiveMetricsKey) }
    }
    private var showMemBreakdown: Bool {
        get { UserDefaults.standard.bool(forKey: showMemBreakdownKey) }
        set { UserDefaults.standard.set(newValue, forKey: showMemBreakdownKey) }
    }
    private var autoReleaseMode: AutoReleaseMode {
        get {
            let raw = UserDefaults.standard.string(forKey: autoReleaseModeKey) ?? AutoReleaseMode.notify.rawValue
            return AutoReleaseMode(rawValue: raw) ?? .notify
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: autoReleaseModeKey) }
    }

    enum Theme: String {
        case liquidGlass = "liquid-glass"
        case fallout     = "fallout"

        var menuTitle: String {
            switch self {
            case .liquidGlass: return "Liquid Glass"
            case .fallout:     return "Fallout Terminal"
            }
        }
    }

    private var theme: Theme {
        get {
            let raw = UserDefaults.standard.string(forKey: themeKey) ?? Theme.liquidGlass.rawValue
            return Theme(rawValue: raw) ?? .liquidGlass
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: themeKey) }
    }

    private enum MetricKind { case cpu, memory, gpu, disk }

    override init() {
        super.init()
        setupStatusItem()
        requestNotificationPermissionIfNeeded()
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
        menu.autoenablesItems = false

        let liveMetrics = NSMenuItem(title: "Show Live Metrics", action: #selector(toggleLiveMetrics), keyEquivalent: "")
        liveMetrics.target = self
        liveMetrics.state  = showLiveMetrics ? .on : .off
        menu.addItem(liveMetrics)

        let breakdown = NSMenuItem(title: "Show Memory Breakdown", action: #selector(toggleMemBreakdown), keyEquivalent: "")
        breakdown.target = self
        breakdown.state  = showMemBreakdown ? .on : .off
        menu.addItem(breakdown)

        // Theme submenu
        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        let themeSub  = NSMenu(title: "Theme")
        for t in [Theme.liquidGlass, .fallout] {
            let it = NSMenuItem(title: t.menuTitle, action: #selector(setTheme(_:)), keyEquivalent: "")
            it.target = self
            it.state  = (theme == t) ? .on : .off
            it.representedObject = t.rawValue
            themeSub.addItem(it)
        }
        themeItem.submenu = themeSub
        menu.addItem(themeItem)

        // Auto-Release submenu
        let autoItem = NSMenuItem(title: "Auto-Release Memory", action: nil, keyEquivalent: "")
        let autoSub  = NSMenu(title: "Auto-Release Memory")
        for mode in [AutoReleaseMode.notify, .autoPassword, .autoSudoers, .off] {
            let it = NSMenuItem(title: mode.menuTitle, action: #selector(setAutoReleaseMode(_:)), keyEquivalent: "")
            it.target = self
            it.state  = (autoReleaseMode == mode) ? .on : .off
            it.representedObject = mode.rawValue
            autoSub.addItem(it)
        }
        autoItem.submenu = autoSub
        menu.addItem(autoItem)

        let releaseNow = NSMenuItem(
            title: "Release Memory Now…",
            action: #selector(releaseNow),
            keyEquivalent: "r"
        )
        releaseNow.keyEquivalentModifierMask = [.command]
        releaseNow.target = self
        releaseNow.isEnabled = !isReleasing
        menu.addItem(releaseNow)

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
        tickCount = 0
        metricIndex = 0
        renderStatusBar(SystemMetrics.snapshot())
    }

    @objc private func toggleMemBreakdown() {
        showMemBreakdown.toggle()
        if let snap = lastSnapshot() { pushMetricsToWebView(snap) }
    }

    @objc private func setAutoReleaseMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = AutoReleaseMode(rawValue: raw) else { return }
        autoReleaseMode = mode
        pressureHighTicks = 0           // reset the hysteresis on mode change
    }

    @objc private func setTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let t   = Theme(rawValue: raw) else { return }
        theme = t
        applyPanelChromeForTheme()
        if let snap = cachedSnap { pushMetricsToWebView(snap) }
    }

    @objc private func releaseNow() {
        triggerRelease(manual: true)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func iconTitle(alert: Bool) -> NSAttributedString {
        let color: NSColor = alert ? .systemRed : pipGreen
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

        if let btn = statusItem.button, let btnWindow = btn.window {
            let btnScreenRect = btnWindow.convertToScreen(btn.frame)
            let pw: CGFloat = 320
            let ph: CGFloat = 460      // breakdown-on needs ≈420; 460 gives a calm bottom margin
            let x = (btnScreenRect.midX - pw / 2).rounded()
            let y = (btnScreenRect.minY - ph).rounded()
            p.setContentSize(NSSize(width: pw, height: ph))
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }

        applyPanelChromeForTheme()
        p.makeKeyAndOrderFront(nil)
        installClickOutsideMonitor()
        tick()
    }

    private func closePanel() {
        removeClickOutsideMonitor()
        panel?.orderOut(nil)
    }

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

    private var vibrancyView: NSVisualEffectView?

    private func buildPanel() {
        let frame = NSRect(x: 0, y: 0, width: 320, height: 460)

        let p = NSPanel(
            contentRect: frame,
            styleMask:   [.nonactivatingPanel, .borderless],
            backing:     .buffered,
            defer:       false
        )
        p.isOpaque                 = false
        p.backgroundColor          = .clear
        p.level                    = .statusBar
        p.collectionBehavior       = [.canJoinAllSpaces, .transient]
        p.isFloatingPanel          = true
        p.hasShadow                = true
        p.isReleasedWhenClosed     = false
        // Pin to dark vibrancy so the hudWindow material always renders its
        // dark translucent variant — otherwise in system Light Mode it goes
        // near-white and buries white-on-glass text.
        p.appearance               = NSAppearance(named: .darkAqua)

        // NSVisualEffectView supplies the desktop-blur behind the liquid glass
        // theme.  For the fallout theme, the opaque CSS body simply covers it.
        let vibrancy = NSVisualEffectView(frame: frame)
        vibrancy.autoresizingMask = [.width, .height]
        vibrancy.material         = .hudWindow    // more translucent than .popover
        vibrancy.state            = .active
        vibrancy.blendingMode     = .behindWindow
        vibrancy.wantsLayer       = true
        vibrancy.layer?.cornerRadius  = 18        // Liquid Glass reads rounder
        vibrancy.layer?.masksToBounds = true

        let config = WKWebViewConfiguration()
        let wv = WKWebView(frame: frame, configuration: config)
        wv.autoresizingMask = [.width, .height]
        // Make the web view transparent so the vibrancy shows through when
        // the CSS body is translucent.  `drawsBackground` is a long-standing
        // private key on WKWebView and still the canonical way to do this.
        wv.setValue(false, forKey: "drawsBackground")
        wv.wantsLayer = true
        wv.layer?.backgroundColor = NSColor.clear.cgColor

        vibrancy.addSubview(wv)
        p.contentView  = vibrancy
        vibrancyView   = vibrancy
        webView        = wv
        panel          = p

        loadWebContent()
    }

    // Called when the panel opens or the user switches themes — tweaks the
    // NSVisualEffectView material so fallout doesn't waste cycles blurring
    // pixels it'll cover up anyway.
    private func applyPanelChromeForTheme() {
        guard let v = vibrancyView else { return }
        switch theme {
        case .liquidGlass:
            v.material     = .hudWindow
            v.blendingMode = .behindWindow
            v.state        = .active
        case .fallout:
            // Still active so corner clipping works, but a cheaper material.
            v.material     = .contentBackground
            v.blendingMode = .withinWindow
            v.state        = .inactive
        }
    }

    private func loadWebContent() {
        guard let wv = webView else { return }

        let candidates: [URL?] = [
            Bundle.main.url(forResource: "index", withExtension: "html"),
            sourceTreeResourceURL()
        ]

        for candidate in candidates {
            guard let url = candidate, FileManager.default.fileExists(atPath: url.path) else { continue }
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            return
        }

        wv.loadHTMLString(
            "<html><body style='background:#0a0f0a;color:#39ff14;font-family:monospace;padding:16px'>" +
            "<p>Free Mac Monitor — resource files not found.<br>Run ./build.sh first.</p></body></html>",
            baseURL: nil
        )
    }

    private func sourceTreeResourceURL() -> URL? {
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

    // MARK: - Polling

    private func startPolling() {
        tick()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(pollingTimer!, forMode: .common)
    }

    private var cachedSnap: MetricsSnapshot?
    private func lastSnapshot() -> MetricsSnapshot? { cachedSnap }

    private func tick() {
        let snap = SystemMetrics.snapshot()
        cachedSnap = snap

        tickCount += 1
        if tickCount >= rotationSeconds {
            tickCount = 0
            metricIndex &+= 1
        }

        evaluateAutoRelease(snap)

        renderStatusBar(snap)

        guard let p = panel, p.isVisible else { return }
        pushMetricsToWebView(snap)
    }

    // MARK: - Auto-release evaluation

    private func evaluateAutoRelease(_ snap: MetricsSnapshot) {
        // No auto-trigger when the animation or a manual release is already in flight.
        if isReleasing || animationTimer != nil { return }

        // Cooldown guard
        if let last = lastReleaseAt,
           Date().timeIntervalSince(last) < autoReleaseCooldownSec {
            return
        }

        let pressure = snap.memBreakdown.pressure
        if pressure >= autoReleaseTriggerPct {
            pressureHighTicks += 1
        } else {
            pressureHighTicks = 0
            return
        }
        guard pressureHighTicks >= autoReleaseHoldTicks else { return }

        switch autoReleaseMode {
        case .off:
            pressureHighTicks = 0
        case .notify:
            pressureHighTicks = 0
            lastReleaseAt = Date()
            postPressureNotification(pressure: pressure)
        case .autoPassword, .autoSudoers:
            pressureHighTicks = 0
            triggerRelease(manual: false)
        }
    }

    private func triggerRelease(manual: Bool) {
        guard !isReleasing else { return }
        let mode = autoReleaseMode

        // For a manual "Release Memory Now…" invocation we ignore .off / .notify
        // and always try to actually run purge — pick a sensible default.
        let runningMode: AutoReleaseMode = {
            if !manual { return mode }
            switch mode {
            case .off, .notify: return .autoPassword
            default:            return mode
            }
        }()
        guard runningMode == .autoPassword || runningMode == .autoSudoers else { return }

        isReleasing   = true
        lastReleaseAt = Date()
        startCleanupAnimation(phase: .flushing)

        MemoryReleaser.release(mode: runningMode) { [weak self] result in
            guard let self = self else { return }
            self.isReleasing = false

            guard let snap = self.cachedSnap else {
                self.finishCleanupAnimation(deltaPct: 0, success: result.success)
                return
            }
            let delta = result.delta(total: snap.memBreakdown.total)
            self.lastReleaseResult = (result.bytesReleased, delta, Date())
            self.finishCleanupAnimation(deltaPct: delta, success: result.success)

            if let err = result.errorMessage, !result.success, err != "cancelled" {
                self.postErrorNotification(err, mode: runningMode)
            }
        }
    }

    // MARK: - Cleanup animation

    private enum AnimPhase { case flushing }

    private func startCleanupAnimation(phase: AnimPhase) {
        // Frames 0–5: [FLUSH ....] → [FLUSH ████] — 6 frames × 200ms each
        // Terminal frames are appended once the purge completes (finishCleanupAnimation).
        animationFrames = [
            (">> MEM \(Int(cachedSnap?.memBreakdown.pressure ?? 0))%",          .systemRed),
            ("[FLUSH ····]", pipAmber),
            ("[FLUSH ▓···]", pipAmber),
            ("[FLUSH ▓▓··]", pipAmber),
            ("[FLUSH ▓▓▓·]", pipAmber),
            ("[FLUSH ▓▓▓▓]", pipAmber),
        ]
        animationIndex = 0
        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            self.advanceAnimation()
        }
        RunLoop.main.add(animationTimer!, forMode: .common)
        renderCurrentAnimationFrame()
    }

    private func advanceAnimation() {
        animationIndex += 1
        if animationIndex >= animationFrames.count {
            animationTimer?.invalidate()
            animationTimer = nil
            return
        }
        renderCurrentAnimationFrame()
    }

    // Called from the async release completion — appends "▼N" result frame
    // and schedules a handoff back to normal rendering.
    private func finishCleanupAnimation(deltaPct: Double, success: Bool) {
        let pressure = cachedSnap?.memBreakdown.pressure ?? 0
        let color: NSColor = success ? pipGreen : pipAmber
        let delta = Int(deltaPct.rounded())
        let text = success
            ? String(format: "MEM %d%% ▼%d", Int(pressure), max(0, delta))
            : "[FLUSH FAIL]"
        animationFrames = [(text, color)]
        animationIndex  = 0
        animationTimer?.invalidate()

        renderCurrentAnimationFrame()

        // Hold the result frame for 900ms, then release the animation lock
        // so the normal tick() rendering can take over.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.animationFrames = []
            self?.animationIndex  = 0
            self?.animationTimer  = nil
            if let snap = self?.cachedSnap { self?.renderStatusBar(snap) }
            // Also push the released-line to the webview for the panel toast.
            if let self = self, let r = self.lastReleaseResult, self.panel?.isVisible == true {
                self.pushReleaseToastToWebView(bytes: r.bytes, at: r.time)
            }
        }
    }

    private func renderCurrentAnimationFrame() {
        guard animationIndex < animationFrames.count else { return }
        let (text, color) = animationFrames[animationIndex]
        statusItem.button?.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: color,
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            ]
        )
    }

    // MARK: - Normal status-bar render (rotating or icon)

    private func renderStatusBar(_ snap: MetricsSnapshot) {
        // If an animation is running it owns the status-bar title.
        if animationTimer != nil || !animationFrames.isEmpty { return }

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

    // MARK: - WebView push

    private func pushMetricsToWebView(_ snap: MetricsSnapshot) {
        guard let data   = try? JSONEncoder().encode(snap),
              let jsBody = String(data: data, encoding: .utf8) else { return }
        let showBreak = showMemBreakdown ? "true" : "false"
        let themeStr  = theme.rawValue
        let js = """
        if(typeof window.updateMetrics==='function'){
          window.updateMetrics(\(jsBody), { showBreakdown: \(showBreak), theme: '\(themeStr)' });
        }
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    private func pushReleaseToastToWebView(bytes: UInt64, at: Date) {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        let mb = Double(bytes) / (1024 * 1024)
        let msg: String
        if mb >= 1024 { msg = String(format: "%.1f GB", mb / 1024) }
        else          { msg = String(format: "%.0f MB", mb) }
        let escaped = msg.replacingOccurrences(of: "'", with: "\\'")
        let js = """
        if(typeof window.showReleaseToast==='function'){
          window.showReleaseToast('\(escaped)', '\(df.string(from: at))');
        }
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Notifications

    private func requestNotificationPermissionIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postPressureNotification(pressure: Double) {
        let c = UNMutableNotificationContent()
        c.title = "Memory pressure high"
        c.body  = String(format: "Memory at %.0f%% — open the menu to release cache.", pressure)
        c.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    private func postErrorNotification(_ message: String, mode: AutoReleaseMode) {
        let c = UNMutableNotificationContent()
        c.title = "Memory release failed"
        c.body  = mode == .autoSudoers
            ? "sudoers-free mode needs a NOPASSWD rule for /usr/sbin/purge. See README."
            : message
        c.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    deinit {
        pollingTimer?.invalidate()
        animationTimer?.invalidate()
        removeClickOutsideMonitor()
    }
}
