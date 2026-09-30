import SwiftUI

/// The repository's pre-commit and pre-push hooks, with their latest runs: the step a
/// running hook is on and for how long, and how long each step took once it's done.
/// Shows nothing when the repository has neither hook.
struct SourceControlHooksView: View {
    @ObservedObject var tracker: GitHookTracker

    /// Sections and hooks the user collapsed or expanded, by id.
    @Binding var toggled: Set<String>

    private static let sectionID = "section:hooks"

    var body: some View {
        if !tracker.scripts.isEmpty {
            let isCollapsed = toggled.contains(Self.sectionID)
            SourceControlSectionHeader(title: "Hooks", count: tracker.scripts.count, isCollapsed: isCollapsed) {
                toggle(Self.sectionID)
            }

            if !isCollapsed {
                ForEach(tracker.scripts, id: \.name) { script in
                    SourceControlHookView(script: script, run: tracker.runs[script.name], toggled: $toggled)
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if toggled.contains(id) { toggled.remove(id) } else { toggled.insert(id) }
    }
}

/// One hook: a line with how its latest run is going or went, and its steps below it.
private struct SourceControlHookView: View {
    let script: GitHookScript
    let run: GitHookRun?
    @Binding var toggled: Set<String>

    private var id: String { "hook:\(script.name)" }

    /// A hook shows its steps once it runs, and the user can collapse or expand it.
    private var isExpanded: Bool {
        (run?.followsSteps ?? false) != toggled.contains(id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header

            if let run {
                if run.outcome == .running, run.followsSteps {
                    ProgressView(value: Double(run.current ?? 0), total: Double(max(run.steps.count, 1)))
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .padding(.leading, 30)
                }
                summary(of: run)
            }

            if isExpanded, let run, run.followsSteps {
                ForEach(Array(run.steps.enumerated()), id: \.offset) { index, step in
                    SourceControlHookStepView(index: index, step: step, run: run)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .onChange(of: run?.startedAt) { _ in
            // A new run shows its steps, even if the last one was collapsed.
            toggled.remove(id)
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .foregroundStyle(.secondary)
                .frame(width: 10)
                .opacity(run?.followsSteps == true ? 1 : 0)

            SourceControlHookStatusIcon(outcome: run?.outcome)
                .frame(width: 14)

            Text(script.name)
                .fontWeight(.medium)
                .lineLimit(1)

            Spacer(minLength: 4)

            trailing
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(height: SourceControlStyle.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            guard run?.followsSteps == true else { return }
            if toggled.contains(id) { toggled.remove(id) } else { toggled.insert(id) }
        }
        .help(help)
    }

    @ViewBuilder
    private var trailing: some View {
        if let run {
            HStack(spacing: 6) {
                if run.followsSteps, let current = run.current, run.outcome == .running || run.outcome == .failed {
                    Text("\(current + 1)/\(run.steps.count)")
                        .fontWeight(.semibold)
                        .foregroundStyle(run.outcome == .failed ? Color(nsColor: .systemRed) : .primary)
                }
                if run.outcome == .running {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(SourceControlHookFormat.duration(context.date.timeIntervalSince(run.startedAt)))
                    }
                } else if let duration = run.duration {
                    Text(SourceControlHookFormat.duration(duration))
                }
            }
        } else if !script.steps.isEmpty {
            Text(script.steps.count == 1 ? "1 step" : "\(script.steps.count) steps")
        }
    }

    /// What the run is doing, or how it ended and when.
    @ViewBuilder
    private func summary(of run: GitHookRun) -> some View {
        let text: String? = {
            switch run.outcome {
            case .running:
                // The steps below show the one running.
                if isExpanded { return run.current == nil ? "Starting…" : nil }
                if let current = run.current { return run.steps[current].title }
                return run.followsSteps ? "Starting…" : "Running"
            case .passed:
                return run.endedAt.map { "Passed \(SourceControlHookFormat.time($0))" }
            case .failed:
                let step = run.current.map { " at \(run.steps[$0].title)" } ?? ""
                return run.endedAt.map { "Failed\(step) · \(SourceControlHookFormat.time($0))" }
            case .ended:
                return run.endedAt.map { "Ended \(SourceControlHookFormat.time($0))" }
            }
        }()
        if let text {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(run.outcome == .failed ? Color(nsColor: .systemRed) : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 30)
        }
    }

    private var help: String {
        var lines = [script.path.path]
        if let run, !run.followsSteps {
            lines.append(script.steps.isEmpty
                ? "The hook announces no steps, such as \"[1/3] Lint…\""
                : "Its steps can't be followed: it runs none of the commands its script names")
        }
        return lines.joined(separator: "\n")
    }
}

private struct SourceControlHookStepView: View {
    let index: Int
    let step: GitHookRun.Step
    let run: GitHookRun

    private enum State {
        case pending, running, done, failed, skipped
    }

    private var state: State {
        if index == run.current {
            switch run.outcome {
            case .running: return .running
            case .failed: return .failed
            default: return .done
            }
        }
        if step.endedAt != nil { return .done }
        if let current = run.current, index < current { return .skipped }
        return .pending
    }

    var body: some View {
        HStack(spacing: 6) {
            icon
                .frame(width: 12)

            Text("\(index + 1). \(step.title)")
                .lineLimit(1)
                .truncationMode(.tail)
                .fontWeight(state == .running ? .semibold : nil)
                .foregroundStyle(state == .pending || state == .skipped ? .secondary : .primary)

            Spacer(minLength: 4)

            duration
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .padding(.leading, 30)
        .frame(height: 18)
        .help(step.title)
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .running:
            ProgressView().controlSize(.mini)
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color(nsColor: .systemGreen))
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color(nsColor: .systemRed))
        case .skipped:
            Image(systemName: "minus")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 7))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var duration: some View {
        switch state {
        case .running:
            if let startedAt = step.startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(SourceControlHookFormat.duration(context.date.timeIntervalSince(startedAt)))
                }
            }
        case .done, .failed:
            // A step the run was past when it was first seen took an unknown time.
            Text(step.duration.map(SourceControlHookFormat.duration) ?? "–")
        case .skipped:
            Text("skipped")
        case .pending:
            EmptyView()
        }
    }
}

private struct SourceControlHookStatusIcon: View {
    let outcome: GitHookRun.Outcome?

    var body: some View {
        switch outcome {
        case .running:
            ProgressView().controlSize(.mini)
        case .passed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(nsColor: .systemGreen))
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Color(nsColor: .systemRed))
        case .ended:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
        case nil:
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
        }
    }
}

enum SourceControlHookFormat {
    /// `<1s`, `42s`, `3m 12s` or `1h 04m`. Steps are timed to within half a second.
    static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        if seconds < 1 { return "<1s" }
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(String(format: "%02d", seconds % 60))s" }
        return "\(seconds / 3600)h \(String(format: "%02d", seconds / 60 % 60))m"
    }

    /// The time, with the day too when it isn't today.
    static func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .standard)
            : date.formatted(date: .abbreviated, time: .standard)
    }
}
