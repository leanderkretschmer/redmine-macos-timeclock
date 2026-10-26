import Foundation

// MARK: - Redmine core

/// Response of `GET /users/current.json`.
nonisolated struct CurrentUserResponse: Decodable, Sendable {
    let user: RedmineUser
}

nonisolated struct RedmineUser: Decodable, Sendable {
    let id: Int
    let login: String?
    let firstname: String?
    let lastname: String?

    var displayName: String {
        let name = [firstname, lastname].compactMap { $0 }.joined(separator: " ")
        return name.isEmpty ? (login ?? "#\(id)") : name
    }
}

/// Response of `GET /issues.json`.
nonisolated struct IssuesResponse: Decodable, Sendable {
    let issues: [Issue]
}

/// Response of `GET /issues/:id.json`.
nonisolated struct IssueResponse: Decodable, Sendable {
    let issue: Issue
}

nonisolated struct Issue: Decodable, Identifiable, Hashable, Sendable {
    nonisolated struct NamedRef: Decodable, Hashable, Sendable {
        let id: Int
        let name: String
    }

    let id: Int
    let subject: String
    let project: NamedRef?
    let status: NamedRef?
}

// MARK: - redmine_human_resources (Stempeluhr)

/// Snapshot returned by `/hr_timeclock/status.json` and all state-changing actions.
nonisolated struct HRSnapshot: Codable, Sendable {
    nonisolated struct PendingCorrection: Codable, Sendable {
        let id: Int
        let startedAtLabel: String?
    }

    let state: String
    let workedSecondsToday: Int
    let currentBreakSeconds: Int
    let totalBreakSecondsToday: Int
    let dailyTargetSeconds: Int
    let expectedEndUnix: Int?
    let pollIntervalSeconds: Int?
    let pendingCorrection: PendingCorrection?

    var clockState: ClockState { ClockState(rawValue: state) ?? .idle }
}

nonisolated enum ClockState: String, Sendable {
    case idle
    case working
    case onBreak = "on_break"
    case needsCorrection = "needs_correction"
}

/// State-changing timeclock endpoints (`POST /hr_timeclock/<action>.json`).
nonisolated enum ClockAction: String, Sendable {
    case start, pause, resume, stop
}

// MARK: - Stopwatch plugin (Zeiterfassung pro Ticket)

/// Response of `GET /stopwatch_timers/current.json` (jkraemer/stopwatch plugin).
nonisolated struct StopwatchTimer: Decodable, Sendable {
    let timeEntryId: Int?
    /// Formatted by Redmine according to the "timespan format" setting, e.g. `"1:05"` or `"1.08"`.
    let timeSpent: String
    let running: Bool
    let issueId: Int?

    /// `timeSpent` converted to seconds, accepting both `H:MM` and decimal formats.
    var spentSeconds: Int {
        let raw = timeSpent.trimmingCharacters(in: .whitespaces)
        if raw.contains(":") {
            let parts = raw.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 else { return 0 }
            return parts[0] * 3600 + parts[1] * 60
        }
        let hours = Double(raw.replacingOccurrences(of: ",", with: ".")) ?? 0
        return Int(hours * 3600)
    }
}
