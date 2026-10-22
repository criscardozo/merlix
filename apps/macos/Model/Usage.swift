import AppKit
import Foundation
import Observation

/// Claude plan usage, read from the status-line usage cache that a menu bar app writes
/// for its status line (`~/.claude/.statusline-usage-cache`, KEY=VALUE lines).
@Observable
final class UsageMonitor {
    static let shared = UsageMonitor()

    struct Window: Equatable {
        /// Used share, 0 to 100.
        var used: Double
        var resetsAt: Date
    }

    private(set) var fiveHours: Window?
    private(set) var week: Window?
    /// The file exists but has not been refreshed recently, so its numbers may be wrong.
    private(set) var stale = false
    private(set) var available = false

    /// The writer refreshes every few minutes; older numbers are not trusted.
    private static let staleAfter: TimeInterval = 15 * 60
    private static let url = URL.homeDirectory.appending(path: ".claude/.statusline-usage-cache")

    @ObservationIgnored private var timer: Timer?

    private init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { UsageMonitor.shared.refresh() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { UsageMonitor.shared.refresh() }
        }
    }

    func refresh() {
        guard let text = try? String(contentsOf: Self.url, encoding: .utf8) else {
            available = false
            return
        }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
        }

        let now = Date.now
        let written = values["TIMESTAMP"].flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
        available = true
        stale = written.map { now.timeIntervalSince($0) > Self.staleAfter } ?? true
        fiveHours = Self.window(values["UTILIZATION"], values["RESETS_AT"], now: now)
        week = Self.window(values["WEEKLY_UTILIZATION"], values["WEEKLY_RESETS_AT"], now: now)
    }

    /// A window whose reset time has passed belongs to an earlier period, so its
    /// number no longer applies.
    private static func window(_ used: String?, _ reset: String?, now: Date) -> Window? {
        guard let used = used.flatMap(Double.init), let reset = reset.flatMap(parseDate), reset > now
        else { return nil }
        return Window(used: min(max(used, 0), 100), resetsAt: reset)
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: string)
    }
}
