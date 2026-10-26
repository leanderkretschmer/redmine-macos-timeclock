import AppKit
import SwiftUI

/// The small window shown when clicking the menu bar item.
struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.showingSettings {
                SettingsView(model: model)
            } else {
                header
                if let error = model.errorMessage {
                    MessageBanner(text: error, systemImage: "exclamationmark.triangle")
                }
                TimeclockSection(model: model)
                if model.isTimerRunning {
                    TicketTimerRow(model: model)
                }
                Divider()
                IssueListSection(model: model)
                Divider()
                footer
            }
        }
        .padding(14)
        .frame(width: 420)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Redmine")
                    .font(.headline)
                if let name = model.userName {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                Task { await model.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Aktualisieren")
            Button {
                model.showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Einstellungen")
        }
    }

    private var footer: some View {
        HStack {
            Button("Stempeluhr im Browser") { model.openTimeclock() }
                .buttonStyle(.link)
            Spacer()
            Button("Beenden") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}

// MARK: - Timeclock

private struct TimeclockSection: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let snapshot = model.snapshot {
                HStack(alignment: .firstTextBaseline) {
                    Label(stateTitle, systemImage: model.menuBarIcon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(stateColor)
                    Spacer()
                    Text(AppModel.formatLong(model.liveWorkedSeconds))
                        .font(.title2.monospacedDigit().weight(.semibold))
                }

                if snapshot.dailyTargetSeconds > 0 {
                    ProgressView(
                        value: Double(min(model.liveWorkedSeconds, snapshot.dailyTargetSeconds)),
                        total: Double(snapshot.dailyTargetSeconds)
                    )
                    HStack {
                        Text("Soll \(AppModel.format(snapshot.dailyTargetSeconds))")
                        Spacer()
                        if model.clockState == .onBreak {
                            Text("Pause \(AppModel.formatLong(model.liveBreakSeconds))")
                        } else if let end = model.expectedEnd {
                            Text("Feierabend ca. \(end.formatted(date: .omitted, time: .shortened))")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if model.clockState == .needsCorrection {
                    MessageBanner(
                        text: "Offener Eintrag\(snapshot.pendingCorrection?.startedAtLabel.map { " vom \($0)" } ?? "") – bitte im Browser korrigieren.",
                        systemImage: "exclamationmark.triangle"
                    )
                }

                actionButtons
                if model.timeclockAccess == .quick {
                    quickModeHint
                }
            } else if model.timeclockAccess == .quick {
                Label("Status unbekannt", systemImage: "clock")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack {
                    actionButton("Einstempeln", systemImage: "play.fill", action: .start, prominent: true)
                    actionButton("Ausstempeln", systemImage: "stop.fill", action: .stop)
                }
                .disabled(model.isPerformingAction)
                quickModeHint
            } else if let message = model.timeclockMessage {
                MessageBanner(text: message, systemImage: "clock.badge.exclamationmark")
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            }
            if model.snapshot != nil, let message = model.timeclockMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack {
            switch model.clockState {
            case .idle:
                actionButton("Einstempeln", systemImage: "play.fill", action: .start, prominent: true)
            case .working:
                if model.timeclockAccess != .quick {
                    actionButton("Pause", systemImage: "pause.fill", action: .pause)
                }
                actionButton("Ausstempeln", systemImage: "stop.fill", action: .stop, prominent: true)
            case .onBreak:
                actionButton("Pause beenden", systemImage: "play.fill", action: .resume, prominent: true)
                actionButton("Ausstempeln", systemImage: "stop.fill", action: .stop)
            case .needsCorrection:
                Button("Im Browser korrigieren") { model.openTimeclock() }
                    .frame(maxWidth: .infinity)
            case nil:
                EmptyView()
            }
        }
        .disabled(model.isPerformingAction)
    }

    private var quickModeHint: some View {
        Text("Nur API-Key: Stempeln über die Quick-Schnittstelle, ohne Pause und Live-Status. Für alle Funktionen Benutzer/Passwort hinterlegen.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func actionButton(_ title: String, systemImage: String, action: ClockAction, prominent: Bool = false) -> some View {
        let button = Button {
            Task { await model.perform(action) }
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private var stateTitle: String {
        switch model.clockState {
        case .working: "Eingestempelt"
        case .onBreak: "In Pause"
        case .needsCorrection: "Korrektur nötig"
        default: "Ausgestempelt"
        }
    }

    private var stateColor: Color {
        switch model.clockState {
        case .working: .green
        case .onBreak: .orange
        case .needsCorrection: .red
        default: .secondary
        }
    }
}

// MARK: - Running ticket timer

private struct TicketTimerRow: View {
    let model: AppModel

    var body: some View {
        Button {
            if let id = model.timer?.issueId { model.openIssue(id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "stopwatch.fill")
                    .foregroundStyle(.tint)
                if let id = model.timer?.issueId {
                    Text("#\(id)")
                        .font(.body.monospacedDigit().weight(.semibold))
                }
                Text(model.timerIssue?.subject ?? "")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text(AppModel.formatLong(model.liveTimerSeconds))
                    .font(.body.monospacedDigit())
            }
            .padding(8)
            .background(.tint.opacity(0.12), in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Ticket im Browser öffnen")
    }
}

// MARK: - Issues

private struct IssueListSection: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Tickets", selection: $model.issueFilter) {
                ForEach(IssueFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.issues.isEmpty {
                Group {
                    if model.isLoadingIssues {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Keine offenen Tickets")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.issues) { issue in
                            IssueRow(issue: issue, isTracking: model.isTimerRunning && model.timer?.issueId == issue.id) {
                                model.openIssue(issue.id)
                            }
                        }
                    }
                }
                // ScrollView has no intrinsic height inside the menu bar window, so size it
                // explicitly: grow with the number of tickets, scroll beyond ~10 rows.
                .frame(height: min(CGFloat(model.issues.count) * 44, 440))
            }
        }
    }
}

private struct IssueRow: View {
    let issue: Issue
    let isTracking: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("#\(issue.id)")
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(issue.subject)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let project = issue.project?.name {
                        Text([project, issue.status?.name].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if isTracking {
                    Image(systemName: "stopwatch.fill")
                        .foregroundStyle(.tint)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .background(isHovered ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("#\(issue.id) im Browser öffnen")
    }
}

// MARK: - Shared

struct MessageBanner: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.orange.opacity(0.12), in: .rect(cornerRadius: 8))
    }
}

#Preview {
    ContentView(model: AppModel())
}
