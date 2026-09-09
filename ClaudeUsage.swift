import AppKit
import Foundation

struct UsageWindow: Codable {
    let label: String
    let percent: Double
    let resetsAt: Date?
}

struct UsageSnapshot: Codable {
    let fiveHour: UsageWindow
    let weekly: UsageWindow
    let scopedWeekly: UsageWindow?
    let extraEnabled: Bool
    let extraPercent: Double
    let extraUsed: Double
    let extraLimit: Double
    let fetchedAt: Date
}

private struct APIResponse: Decodable {
    struct Limit: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable {
                let displayName: String?

                enum CodingKeys: String, CodingKey {
                    case displayName = "display_name"
                }
            }

            let model: Model?
        }

        let kind: String
        let percent: Double
        let resetsAt: String?
        let scope: Scope?

        enum CodingKeys: String, CodingKey {
            case kind, percent, scope
            case resetsAt = "resets_at"
        }
    }

    struct ExtraUsage: Decodable {
        let isEnabled: Bool
        let utilization: Double?
        let usedCredits: Double?
        let monthlyLimit: Double?
        let decimalPlaces: Int?

        enum CodingKeys: String, CodingKey {
            case utilization
            case isEnabled = "is_enabled"
            case usedCredits = "used_credits"
            case monthlyLimit = "monthly_limit"
            case decimalPlaces = "decimal_places"
        }
    }

    let limits: [Limit]
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case limits
        case extraUsage = "extra_usage"
    }
}

enum UsageError: LocalizedError {
    case noToken
    case invalidResponse
    case http(Int, String)
    case missingLimits
    case rateLimited(until: Date)
    case unauthorized
    case refreshFailed(String)

    var errorDescription: String? {
        switch self {
        case .noToken:
            return "Claude login was not found. Run `claude login` and refresh."
        case .invalidResponse:
            return "Anthropic returned an invalid usage response."
        case .http(let status, let message):
            return "Usage request failed (HTTP \(status)): \(message)"
        case .missingLimits:
            return "The usage response did not include the 5-hour and weekly limits."
        case .rateLimited(let until):
            return "Anthropic rate-limited usage. Retrying at \(Self.clock.string(from: until))."
        case .unauthorized:
            return "Claude login expired. Run `claude login` and refresh."
        case .refreshFailed(let message):
            return "Could not refresh Claude login: \(message)"
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_CA")
        formatter.dateFormat = "h:mma"
        return formatter
    }()
}

struct FetchOutcome {
    let result: Result<UsageSnapshot, Error>
    let retryAfter: TimeInterval
}

enum UsageClient {
    static let defaultInterval: TimeInterval = 15 * 60
    private static let refreshSkew: TimeInterval = 5 * 60
    private static let minBackoff: TimeInterval = 30
    private static let maxBackoff: TimeInterval = 60 * 60
    private static let service = "Claude Code-credentials"
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let tokenURLs = [
        "https://platform.claude.com/v1/oauth/token",
        "https://console.anthropic.com/v1/oauth/token"
    ]
    private static let queue = DispatchQueue(label: "local.claude-usage.fetch")

    static func fetch(completion: @escaping (FetchOutcome) -> Void) {
        queue.async {
            do {
                var credentials = try loadCredentials()
                try ensureFreshAccessToken(&credentials)
                completion(requestUsage(credentials: credentials, retriedAuth: false))
            } catch {
                completion(FetchOutcome(result: .failure(error), retryAfter: defaultInterval))
            }
        }
    }

    private static func requestUsage(credentials: Credentials, retriedAuth: Bool) -> FetchOutcome {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 10
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("claude-code/\(claudeVersion())", forHTTPHeaderField: "User-Agent")

        let (data, response, error) = send(request)
        if let error {
            return FetchOutcome(result: .failure(error), retryAfter: defaultInterval)
        }
        guard let http = response as? HTTPURLResponse, let data else {
            return FetchOutcome(result: .failure(UsageError.invalidResponse), retryAfter: defaultInterval)
        }

        if http.statusCode == 401 {
            if retriedAuth {
                return FetchOutcome(result: .failure(UsageError.unauthorized), retryAfter: defaultInterval)
            }
            do {
                var refreshed = try loadCredentials()
                try refreshAccessToken(&refreshed)
                return requestUsage(credentials: refreshed, retriedAuth: true)
            } catch {
                return FetchOutcome(result: .failure(error), retryAfter: defaultInterval)
            }
        }

        if http.statusCode == 429 {
            let until = Date().addingTimeInterval(retryAfter(from: http))
            return FetchOutcome(
                result: .failure(UsageError.rateLimited(until: until)),
                retryAfter: retryAfter(from: http)
            )
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(300)
            return FetchOutcome(
                result: .failure(UsageError.http(http.statusCode, String(message))),
                retryAfter: defaultInterval
            )
        }

        do {
            let payload = try JSONDecoder().decode(APIResponse.self, from: data)
            return FetchOutcome(result: .success(try snapshot(from: payload)), retryAfter: defaultInterval)
        } catch {
            return FetchOutcome(result: .failure(error), retryAfter: defaultInterval)
        }
    }

    private struct Credentials {
        var account: String
        var blob: [String: Any]
        var accessToken: String
        var refreshToken: String
        var expiresAtMs: Double?
    }

    private static func loadCredentials() throws -> Credentials {
        let dump = run("/usr/bin/security", ["find-generic-password", "-s", service])
        let secret = run("/usr/bin/security", ["find-generic-password", "-s", service, "-w"])
        guard secret.status == 0, let blob = jsonObject(secret.stdout) else {
            throw UsageError.noToken
        }
        guard let oauth = blob["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String, !access.isEmpty else {
            throw UsageError.noToken
        }
        let refresh = oauth["refreshToken"] as? String ?? ""
        let account = keychainAccount(from: dump.stdout) ?? NSUserName()
        return Credentials(
            account: account,
            blob: blob,
            accessToken: access,
            refreshToken: refresh,
            expiresAtMs: oauth["expiresAt"] as? Double ?? (oauth["expiresAt"] as? NSNumber)?.doubleValue
        )
    }

    private static func ensureFreshAccessToken(_ credentials: inout Credentials) throws {
        if let expiresAtMs = credentials.expiresAtMs {
            let expiresAt = Date(timeIntervalSince1970: expiresAtMs / 1000)
            if expiresAt.timeIntervalSinceNow > refreshSkew { return }
        }
        try refreshAccessToken(&credentials)
    }

    private static func refreshAccessToken(_ credentials: inout Credentials) throws {
        guard !credentials.refreshToken.isEmpty else {
            throw UsageError.unauthorized
        }

        var lastError = UsageError.refreshFailed("token endpoint unavailable")
        for urlString in tokenURLs {
            var request = URLRequest(url: URL(string: urlString)!)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "grant_type": "refresh_token",
                "refresh_token": credentials.refreshToken,
                "client_id": clientID
            ])

            let (data, response, error) = send(request)
            if let error {
                lastError = .refreshFailed(error.localizedDescription)
                continue
            }
            guard let http = response as? HTTPURLResponse, let data else {
                lastError = .refreshFailed("empty token response")
                continue
            }
            if http.statusCode == 404 || http.statusCode == 405 { continue }
            guard (200..<300).contains(http.statusCode),
                  let body = jsonObject(data),
                  let access = body["access_token"] as? String, !access.isEmpty else {
                let message = String(decoding: data, as: UTF8.self).prefix(200)
                lastError = .refreshFailed("HTTP \(http.statusCode) \(message)")
                if http.statusCode == 400 || http.statusCode == 401 {
                    throw UsageError.unauthorized
                }
                continue
            }

            credentials.accessToken = access
            if let rotated = body["refresh_token"] as? String, !rotated.isEmpty {
                credentials.refreshToken = rotated
            }
            let lifetime = (body["expires_in"] as? Double) ?? (body["expires_in"] as? NSNumber)?.doubleValue ?? 28800
            credentials.expiresAtMs = Date().timeIntervalSince1970 * 1000 + lifetime * 1000
            try saveCredentials(credentials)
            return
        }
        throw lastError
    }

    private static func saveCredentials(_ credentials: Credentials) throws {
        var blob = credentials.blob
        var oauth = blob["claudeAiOauth"] as? [String: Any] ?? [:]
        oauth["accessToken"] = credentials.accessToken
        oauth["refreshToken"] = credentials.refreshToken
        if let expiresAtMs = credentials.expiresAtMs {
            oauth["expiresAt"] = expiresAtMs
        }
        blob["claudeAiOauth"] = oauth
        let data = try JSONSerialization.data(withJSONObject: blob, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw UsageError.refreshFailed("could not encode credentials")
        }
        let result = run("/usr/bin/security", [
            "add-generic-password", "-U",
            "-s", service,
            "-a", credentials.account,
            "-w", json
        ])
        if result.status != 0 {
            throw UsageError.refreshFailed(result.stderr.isEmpty ? "Keychain write failed" : result.stderr)
        }
    }

    private static func retryAfter(from http: HTTPURLResponse) -> TimeInterval {
        guard let header = http.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces) else {
            return defaultInterval
        }
        if let seconds = TimeInterval(header) {
            return min(max(seconds, minBackoff), maxBackoff)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: header) {
            return min(max(date.timeIntervalSinceNow, minBackoff), maxBackoff)
        }
        return defaultInterval
    }

    private static func send(_ request: URLRequest) -> (Data?, URLResponse?, Error?) {
        let semaphore = DispatchSemaphore(value: 0)
        var captured: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        URLSession.shared.dataTask(with: request) { data, response, error in
            captured = (data, response, error)
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return captured
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func keychainAccount(from dump: Data) -> String? {
        guard let text = String(data: dump, encoding: .utf8) else { return nil }
        guard let range = text.range(of: #""acct"<blob>="([^"]+)""#, options: .regularExpression) else {
            return nil
        }
        let match = String(text[range])
        return match.split(separator: "\"").dropLast().last.map(String.init)
    }

    private static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, stdout: Data, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (1, Data(), error.localizedDescription)
        }
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, output.fileHandleForReading.readDataToEndOfFile(), stderr)
    }

    private static func claudeVersion() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["claude", "--version"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        ]) { _, preferred in preferred }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init) ?? "unknown"
    }

    private static func snapshot(from payload: APIResponse) throws -> UsageSnapshot {
        guard let five = payload.limits.first(where: { $0.kind == "session" }),
              let weekly = payload.limits.first(where: { $0.kind == "weekly_all" }) else {
            throw UsageError.missingLimits
        }
        let scoped = payload.limits.first {
            $0.kind == "weekly_scoped"
                && $0.scope?.model?.displayName?.localizedCaseInsensitiveContains("Fable") == true
        } ?? payload.limits.first(where: { $0.kind == "weekly_scoped" })

        let extra = payload.extraUsage
        let divisor = pow(10.0, Double(extra?.decimalPlaces ?? 2))

        return UsageSnapshot(
            fiveHour: window(five, fallbackLabel: "Current session"),
            weekly: window(weekly, fallbackLabel: "Current week (all models)"),
            scopedWeekly: scoped.map {
                window($0, fallbackLabel: "Current week (\($0.scope?.model?.displayName ?? "model-specific"))")
            },
            extraEnabled: extra?.isEnabled ?? false,
            extraPercent: extra?.utilization ?? 0,
            extraUsed: (extra?.usedCredits ?? 0) / divisor,
            extraLimit: (extra?.monthlyLimit ?? 0) / divisor,
            fetchedAt: Date()
        )
    }

    private static func window(_ limit: APIResponse.Limit, fallbackLabel: String) -> UsageWindow {
        let model = limit.scope?.model?.displayName
        let label = model.map { "Current week (\($0))" } ?? fallbackLabel
        return UsageWindow(label: label, percent: limit.percent, resetsAt: parseDate(limit.resetsAt))
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

func usageColor(_ percent: Double) -> NSColor {
    if percent >= 90 { return .systemRed }
    if percent >= 70 { return .systemOrange }
    return .systemGreen
}

/// Draws the solid rounded background. Menus are always rendered with a
/// translucent system material, so the details live in a panel we paint.
final class PanelBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        NSColor.windowBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

final class MeterView: NSView {
    private let percent: Double

    init(percent: Double) {
        self.percent = percent
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("MeterView is created in code only")
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let fraction = max(0, min(1, percent / 100))
        guard fraction > 0 else { return }
        let filled = NSRect(x: 0, y: 0, width: max(bounds.height, bounds.width * fraction), height: bounds.height)
        usageColor(percent).setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let panelWidth: CGFloat = 300
    private static let panelInset: CGFloat = 14
    private static let contentWidth: CGFloat = panelWidth - panelInset * 2

    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var timer: Timer?
    private var clickMonitors: [Any] = []
    private var snapshot: UsageSnapshot?
    private var refreshError: String?
    private var refreshing = false
    private var consecutiveFailures = 0
    private var backoffUntil: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        snapshot = Cache.load()
        render()
        refresh()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(woke),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func woke() {
        if let backoffUntil, backoffUntil > Date() {
            scheduleRefresh(after: backoffUntil.timeIntervalSinceNow)
            return
        }
        refresh()
    }

    @objc private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        render()
        UsageClient.fetch { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshing = false
                switch outcome.result {
                case .success(let value):
                    self.snapshot = value
                    self.refreshError = nil
                    self.consecutiveFailures = 0
                    self.backoffUntil = nil
                    Cache.save(value)
                    self.scheduleRefresh(after: outcome.retryAfter)
                case .failure(let error):
                    self.refreshError = error.localizedDescription
                    self.consecutiveFailures += 1
                    let delay = self.delay(for: error, suggested: outcome.retryAfter)
                    self.backoffUntil = Date().addingTimeInterval(delay)
                    self.scheduleRefresh(after: delay)
                }
                self.render()
            }
        }
    }

    private func delay(for error: Error, suggested: TimeInterval) -> TimeInterval {
        if case UsageError.rateLimited = error {
            return suggested
        }
        let exponential = 60 * pow(2.0, Double(max(consecutiveFailures - 1, 0)))
        return min(UsageClient.defaultInterval, max(suggested == UsageClient.defaultInterval ? exponential : suggested, 30))
    }

    private func scheduleRefresh(after interval: TimeInterval) {
        timer?.invalidate()
        let wait = max(interval, 5)
        timer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func render() {
        renderTitle()
        if panel != nil, panel.isVisible {
            rebuildPanel()
        }
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            closePanel()
        } else {
            openPanel()
        }
    }

    private func openPanel() {
        rebuildPanel()
        panel.orderFrontRegardless()
        statusItem.button?.highlight(true)
        installClickMonitors()
    }

    @objc private func closePanel() {
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors.removeAll()
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
    }

    private func installClickMonitors() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let outside = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            DispatchQueue.main.async { self?.closePanel() }
        }) {
            clickMonitors.append(outside)
        }
        if let inside = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            guard let self else { return event }
            // The status item handles its own clicks, otherwise it would reopen
            // the panel this monitor just closed.
            if event.window !== self.panel && event.window !== self.statusItem.button?.window {
                self.closePanel()
            }
            return event
        }) {
            clickMonitors.append(inside)
        }
    }

    private func rebuildPanel() {
        let background = PanelBackgroundView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)

        let inset = Self.panelInset
        NSLayoutConstraint.activate([
            background.widthAnchor.constraint(equalToConstant: Self.panelWidth),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -inset)
        ])

        if let snapshot {
            stack.addArrangedSubview(meterRow(snapshot.fiveHour))
            stack.addArrangedSubview(meterRow(snapshot.weekly))
            if let scoped = snapshot.scopedWeekly {
                stack.addArrangedSubview(meterRow(scoped))
            }
            stack.addArrangedSubview(creditsRow(snapshot))
        } else {
            stack.addArrangedSubview(
                secondaryLabel(refreshing ? "Fetching Claude usage…" : "Claude usage unavailable")
            )
        }

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(secondaryLabel(statusText()))

        if let refreshError {
            let warning = secondaryLabel(refreshError)
            warning.textColor = .systemOrange
            warning.lineBreakMode = .byWordWrapping
            warning.maximumNumberOfLines = 3
            warning.preferredMaxLayoutWidth = Self.panelWidth - inset * 2
            warning.toolTip = refreshError
            stack.addArrangedSubview(warning)
        }

        stack.addArrangedSubview(buttonRow())

        // Every row spans the same width so the meters line up exactly.
        for row in stack.arrangedSubviews {
            row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        }

        panel.contentView = background
        background.layoutSubtreeIfNeeded()
        positionPanel(size: background.fittingSize)
    }

    private func positionPanel(size: NSSize) {
        guard let button = statusItem.button, let window = button.window else { return }
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        var x = buttonFrame.midX - size.width / 2
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        let frame = NSRect(x: x, y: buttonFrame.minY - size.height - 6, width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
    }

    private func statusText() -> String {
        guard let snapshot else {
            return refreshing ? "Fetching…" : "No usage data yet"
        }
        let age = RelativeDateTimeFormatter().localizedString(for: snapshot.fetchedAt, relativeTo: Date())
        return "\(refreshError == nil ? "Updated" : "Stale, last updated") \(age)"
    }

    private func renderTitle() {
        guard let button = statusItem.button else { return }
        guard let snapshot else {
            button.title = refreshing ? "Claude …" : "Claude ⚠︎"
            return
        }

        let title = NSMutableAttributedString()
        append("5h", percent: snapshot.fiveHour.percent, to: title)
        append("7d", percent: snapshot.weekly.percent, to: title)
        if let scoped = snapshot.scopedWeekly {
            append(shortLabel(for: scoped), percent: scoped.percent, to: title)
        }
        if refreshError != nil {
            title.append(NSAttributedString(string: " ⚠︎", attributes: [.foregroundColor: NSColor.systemOrange]))
        }
        button.attributedTitle = title
        button.toolTip = "Claude usage. Click for details."
    }

    /// Dim label, bright number: the percentages stay readable at a glance
    /// while the labels stay out of the way.
    private func append(_ label: String, percent: Double, to title: NSMutableAttributedString) {
        if title.length > 0 {
            title.append(NSAttributedString(string: "   "))
        }
        title.append(NSAttributedString(string: label + " ", attributes: [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.systemFont(ofSize: 11)
        ]))

        let color: NSColor
        if percent >= 90 {
            color = .systemRed
        } else if percent >= 70 {
            color = .systemOrange
        } else {
            color = .labelColor
        }
        title.append(NSAttributedString(string: "\(rounded(percent))%", attributes: [
            .foregroundColor: color,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        ]))
    }

    /// "Current week (Fable)" becomes "F".
    private func shortLabel(for window: UsageWindow) -> String {
        guard let open = window.label.firstIndex(of: "("),
              let initial = window.label[window.label.index(after: open)...].first else {
            return "wk"
        }
        return String(initial).uppercased()
    }

    private func meterRow(_ window: UsageWindow) -> NSView {
        let detail = window.resetsAt.map { "Resets \(format($0)) (\(TimeZone.current.identifier))" }
        return meterRow(title: window.label, percent: window.percent, detail: detail)
    }

    private func creditsRow(_ snapshot: UsageSnapshot) -> NSView {
        guard snapshot.extraEnabled else {
            let row = NSStackView(views: [titleLabel("Usage credits"), secondaryLabel("Extra usage is disabled")])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 6
            return row
        }

        let currency = NumberFormatter()
        currency.numberStyle = .currency
        currency.currencyCode = "USD"
        let used = currency.string(from: snapshot.extraUsed as NSNumber) ?? "$\(snapshot.extraUsed)"
        let limit = currency.string(from: snapshot.extraLimit as NSNumber) ?? "$\(snapshot.extraLimit)"

        return meterRow(
            title: "Usage credits",
            percent: snapshot.extraPercent,
            detail: "\(used) / \(limit) spent · Resets \(nextMonth())"
        )
    }

    private func meterRow(title: String, percent: Double, detail: String?) -> NSView {
        let name = titleLabel(title)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let value = NSTextField(labelWithString: "\(rounded(percent))% used")
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        value.textColor = usageColor(percent)
        value.setContentHuggingPriority(.required, for: .horizontal)
        value.setContentCompressionResistancePriority(.required, for: .horizontal)

        let header = NSStackView(views: [name, value])
        header.orientation = .horizontal
        header.spacing = 8
        header.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true

        let meter = MeterView(percent: percent)
        meter.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            meter.heightAnchor.constraint(equalToConstant: 8),
            meter.widthAnchor.constraint(equalToConstant: Self.contentWidth)
        ])

        let row = NSStackView(views: [header, meter])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 6
        if let detail {
            row.addArrangedSubview(secondaryLabel(detail))
        }
        return row
    }

    private func buttonRow() -> NSView {
        let refreshButton = NSButton(
            title: refreshing ? "Refreshing…" : "Refresh Now",
            target: self,
            action: #selector(refresh)
        )
        refreshButton.isEnabled = !refreshing
        let quitButton = NSButton(title: "Quit", target: self, action: #selector(quit))

        for button in [refreshButton, quitButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.setContentHuggingPriority(.required, for: .horizontal)
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [refreshButton, spacer, quitButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func titleLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func secondaryLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func rounded(_ value: Double) -> Int {
        Int(value.rounded())
    }

    private func format(_ date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_CA")
        formatter.timeZone = .current
        if calendar.isDate(date, inSameDayAs: Date()) {
            formatter.dateFormat = "h:mma"
        } else {
            formatter.dateFormat = "MMM d 'at' h:mma"
        }
        return formatter.string(from: date).lowercased()
    }

    private func nextMonth() -> String {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .month, for: Date())!.start
        let next = calendar.date(byAdding: .month, value: 1, to: start)!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_CA")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: next)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

enum Cache {
    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Claude Usage/usage.json")
    }

    static func load() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(UsageSnapshot.self, from: data)
    }

    static func save(_ snapshot: UsageSnapshot) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Could not save Claude usage cache: \(error)")
        }
    }
}

@main
enum ClaudeUsageApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
