import SwiftUI

/// The cup at the bottom of the tab sidebar. Off, it offers to keep the Mac awake, with
/// a time limit and a battery floor for the run. On, it is filled, shows the time left,
/// and offers to turn it off.
struct CaffeineButton: View {
    @ObservedObject var caffeine = Caffeine.shared
    @State private var isShowingPopover = false

    var body: some View {
        Button {
            isShowingPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: caffeine.run == nil ? "cup.and.saucer" : "cup.and.saucer.fill")
                if let run = caffeine.run, let until = run.until {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(CaffeineFormat.remaining(until.timeIntervalSince(context.date)))
                            .monospacedDigit()
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(caffeine.run == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
        .help(caffeine.run == nil ? "Keep this Mac awake" : "Keeping this Mac awake")
        .popover(isPresented: $isShowingPopover, arrowEdge: .top) {
            CaffeinePopover(caffeine: caffeine) { isShowingPopover = false }
        }
    }
}

private struct CaffeinePopover: View {
    @ObservedObject var caffeine: Caffeine
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let run = caffeine.run {
                running(run)
            } else {
                starting
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    @ViewBuilder
    private var starting: some View {
        Text("Keep this Mac awake")
            .font(.headline)
        Text("It stays awake and online with the screen off, even with the lid closed.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if let reason = caffeine.lastStop {
            Label(CaffeineFormat.stopped(reason), systemImage: "info.circle")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Text("Stop after")
                    .gridColumnAlignment(.trailing)
                Picker("Stop after", selection: $caffeine.hours) {
                    ForEach(Caffeine.hourChoices, id: \.self) { hours in
                        Text(hours == 0 ? "No limit" : "\(hours) \(hours == 1 ? "hour" : "hours")").tag(hours)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            GridRow {
                Text("Stop at battery")
                Picker("Stop at battery", selection: $caffeine.minimumBattery) {
                    ForEach(Caffeine.batteryChoices, id: \.self) { percent in
                        Text(percent == 0 ? "Never" : "\(percent)%").tag(percent)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }

        HStack {
            Spacer()
            Button("Keep Awake") {
                // Closed first, so the password prompt doesn't show over it.
                dismiss()
                DispatchQueue.main.async { caffeine.start() }
            }
            .keyboardShortcut(.defaultAction)
        }

        Text("The first time, macOS asks for your password to allow staying awake with the lid closed. It turns off when Maggie quits.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func running(_ run: Caffeine.Run) -> some View {
        Label("Keeping this Mac awake", systemImage: "cup.and.saucer.fill")
            .font(.headline)
            .foregroundStyle(.orange)

        VStack(alignment: .leading, spacing: 4) {
            Text(run.until.map { "Until \($0.formatted(date: .omitted, time: .shortened))" } ?? "Until you turn it off")
            if let minimum = run.minimumBattery {
                Text("Or until the battery is at \(minimum)%")
            }
        }
        .foregroundStyle(.secondary)

        if !run.coversClosedLid {
            Label("Closing the lid still puts it to sleep: the password prompt was cancelled.",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack {
            Spacer()
            Button("Turn Off") {
                caffeine.stop()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}

enum CaffeineFormat {
    /// "3h 12m", "12m", or "0m" once it's up.
    static func remaining(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int((interval / 60).rounded(.up)))
        let hours = minutes / 60
        return hours > 0 ? "\(hours)h \(minutes % 60)m" : "\(minutes)m"
    }

    static func stopped(_ reason: Caffeine.StopReason) -> String {
        switch reason {
        case .timeLimit: return "The last run stopped at its time limit."
        case .battery(let percent): return "The last run stopped with the battery at \(percent)%."
        }
    }
}
