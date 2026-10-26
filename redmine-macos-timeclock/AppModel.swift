import AppKit
import Foundation
import Observation

enum IssueFilter: String, CaseIterable, Identifiable {
    case assigned, watched

    var id: String { rawValue }

    var title: String {
        switch self {
        case .assigned: "Zugewiesen"
        case .watched: "Beobachtet"
        }
    }
}

/// Central state: polls Redmine, keeps live counters ticking and runs timeclock actions.
@Observable
final class AppModel {
    private(set) var settings = ConnectionSettings.load()
    var showingSettings = false

    private(set) var userName: String?
    private(set) var snapshot: HRSnapshot?
    private(set) var timer: StopwatchTimer?
    private(set) var timerIssue: Issue?
    private(set) var issues: [Issue] = []
    private(set) var isLoadingIssues = false
    private(set) var isPerformingAction = false
    private(set) var errorMessage: String?
    private(set) var timeclockMessage: String?
    /// Which timeclock interface is in use; `.quick` means no pause and no live server status.
    private(set) var timeclockAccess: TimeclockAccess?
    private(set) var now = Date()

    var issueFilter: IssueFilter {
        didSet {
            UserDefaults.standard.set(issueFilter.rawValue, forKey: "issueFilter")
            issues = []
            Task { await refreshIssues() }
        }
    }

    /// Local time at which `snapshot` / `timer` were received; used to extrapolate live values.
    private var snapshotDate = Date()
    private var timerDate = Date()

    private let client = RedmineClient()
    private var pollTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?

    init() {
        issueFilter = IssueFilter(rawValue: UserDefaults.standard.string(forKey: "issueFilter") ?? "") ?? .assigned
        showingSettings = settings.clientConfiguration == nil
        startPolling()
        startTicking()
    }

    var isConfigured: Bool { settings.clientConfiguration != nil }

    // MARK: - Live values

    var clockState: ClockState? { snapshot?.clockState }

    var liveWorkedSeconds: Int {
        guard let snapshot else { return 0 }
        let extra = snapshot.clockState == .working ? elapsed(since: snapshotDate) : 0
        return snapshot.workedSecondsToday + extra
    }

    var liveBreakSeconds: Int {
        guard let snapshot, snapshot.clockState == .onBreak else { return 0 }
        return snapshot.currentBreakSeconds + elapsed(since: snapshotDate)
    }

    var liveTimerSeconds: Int {
        guard let timer else { return 0 }
        return timer.spentSeconds + (timer.running ? elapsed(since: timerDate) : 0)
    }

    var isTimerRunning: Bool { timer?.running == true && timer?.issueId != nil }

    var expectedEnd: Date? {
        snapshot?.expectedEndUnix.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    private func elapsed(since date: Date) -> Int {
        max(0, Int(now.timeIntervalSince(date)))
    }

    // MARK: - Menu bar label

    var menuBarIcon: String {
        switch clockState {
        case .working: "clock.fill"
        case .onBreak: "cup.and.saucer.fill"
        case .needsCorrection: "exclamationmark.triangle.fill"
        default: "clock"
        }
    }

    var menuBarTitle: String {
        var parts: [String] = []
        switch clockState {
        case .working: parts.append(Self.format(liveWorkedSeconds))
        case .onBreak: parts.append("Pause \(Self.format(liveBreakSeconds))")
        default: break
        }
        if isTimerRunning, let issueId = timer?.issueId {
            parts.append("#\(issueId) \(Self.format(liveTimerSeconds))")
        }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - Settings

    func apply(_ newSettings: ConnectionSettings) async -> String? {
        newSettings.save()
        settings = newSettings
        userName = nil
        snapshot = nil
        timeclockAccess = nil
        timeclockMessage = nil
        timer = nil
        timerIssue = nil
        issues = []
        await refreshAll()
        if errorMessage == nil { showingSettings = false }
        return errorMessage
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshAll()
                let interval = self.snapshot?.pollIntervalSeconds ?? 30
                try? await Task.sleep(for: .seconds(min(max(interval, 10), 60)))
            }
        }
    }

    /// Advances `now` every second while something is running, so labels update live.
    private func startTicking() {
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if self.clockState == .working || self.clockState == .onBreak || self.timer?.running == true {
                    self.now = Date()
                }
            }
        }
    }

    func refreshAll() async {
        guard let configuration = settings.clientConfiguration else {
            errorMessage = nil
            return
        }
        await client.configure(configuration)
        do {
            if userName == nil {
                userName = try await client.currentUser().displayName
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        await refreshSnapshot()
        await refreshTimer()
        await refreshIssues()
    }

    private func refreshSnapshot() async {
        do {
            let status = try await client.timeclockStatus()
            timeclockAccess = await client.timeclockAccess
            if let status {
                snapshot = status
                snapshotDate = Date()
                now = snapshotDate
            } else if snapshot == nil {
                // Quick mode has no read endpoint – show the last known state from today.
                restoreQuickSnapshot()
            }
            timeclockMessage = nil
        } catch RedmineError.notFound {
            snapshot = nil
            timeclockMessage = "HR-Plugin (redmine_human_resources) nicht gefunden."
        } catch {
            timeclockMessage = error.localizedDescription
        }
    }

    private func refreshTimer() async {
        do {
            let current = try await client.stopwatchCurrent()
            timer = current
            timerDate = Date()
            if current.running, let issueId = current.issueId {
                if timerIssue?.id != issueId {
                    timerIssue = issues.first { $0.id == issueId }
                    if timerIssue == nil {
                        timerIssue = try? await client.issue(id: issueId)
                    }
                }
            } else {
                timerIssue = nil
            }
        } catch {
            // Stopwatch plugin missing or not accessible – simply hide the timer.
            timer = nil
            timerIssue = nil
        }
    }

    func refreshIssues() async {
        guard isConfigured else { return }
        isLoadingIssues = true
        defer { isLoadingIssues = false }
        let filter = issueFilter
        do {
            let result = try await client.issues(watched: filter == .watched)
            // Ignore stale responses if the filter changed while loading.
            if filter == issueFilter { issues = result }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Actions

    func perform(_ action: ClockAction) async {
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            let result = try await client.perform(action)
            timeclockAccess = await client.timeclockAccess
            snapshot = result
            snapshotDate = Date()
            now = snapshotDate
            timeclockMessage = nil
            if timeclockAccess == .quick { storeQuickSnapshot(result) }
        } catch {
            timeclockMessage = error.localizedDescription
        }
    }

    // MARK: - Quick mode persistence

    private static let quickSnapshotKey = "quickSnapshot"
    private static let quickSnapshotDateKey = "quickSnapshotDate"

    private func storeQuickSnapshot(_ snapshot: HRSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.quickSnapshotKey)
        UserDefaults.standard.set(Date(), forKey: Self.quickSnapshotDateKey)
    }

    private func restoreQuickSnapshot() {
        let defaults = UserDefaults.standard
        guard let date = defaults.object(forKey: Self.quickSnapshotDateKey) as? Date,
              Calendar.current.isDateInToday(date),
              let data = defaults.data(forKey: Self.quickSnapshotKey),
              let stored = try? JSONDecoder().decode(HRSnapshot.self, from: data) else { return }
        snapshot = stored
        snapshotDate = date
        now = Date()
    }

    func openIssue(_ id: Int) {
        open(path: "/issues/\(id)")
    }

    func openTimeclock() {
        open(path: "/hr_timeclock")
    }

    private func open(path: String) {
        guard var base = settings.baseURL?.absoluteString else { return }
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Formatting

    /// `H:MM`
    static func format(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 3600, (s % 3600) / 60)
    }

    /// `H:MM:SS`
    static func formatLong(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
