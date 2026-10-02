import SwiftUI

/// The app's settings: which coding agent new sessions start, and whether they start one.
/// Everything else Ghostty configures is in its configuration file, which the view opens.
struct SettingsView: View {
    @ObservedObject private var agentSettings = CodingAgentSettings.shared
    @ObservedObject private var agentStart = AgentStart.shared

    /// What each agent's command reported, once asked: its version, or nil when it isn't
    /// installed. Missing while it hasn't answered.
    @State private var installed: [CodingAgent: String?] = [:]

    var openConfiguration: () -> Void = {}

    var body: some View {
        Form {
            Section {
                Picker("Agent", selection: $agentSettings.agent) {
                    ForEach(CodingAgent.allCases, id: \.self) { agent in
                        Text(agent.displayName).tag(agent)
                    }
                }
                .pickerStyle(.radioGroup)

                Toggle("Start \(agentSettings.agent.displayName) in new sessions", isOn: $agentStart.isEnabled)
            } header: {
                Text("Coding Agent")
            } footer: {
                Text("A new session types the start command into its shell, in the session's own worktree inside a git repository. A restored session resumes the session it was running, whichever agent that was.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Installed") {
                ForEach(CodingAgent.allCases, id: \.self) { agent in
                    LabeledContent(agent.displayName) {
                        installedText(agent)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                LabeledContent("Terminal") {
                    Button("Open Configuration File…", action: openConfiguration)
                }
            } footer: {
                Text("Fonts, colors, keybindings and the rest are set in the configuration file.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .task { await checkInstalled() }
    }

    @ViewBuilder
    private func installedText(_ agent: CodingAgent) -> some View {
        switch installed[agent] {
        case .none: Text("Checking…")
        case .some(.none): Text("Not installed")
        case .some(.some(let version)): Text(version)
        }
    }

    /// Asks each agent's command for its version, off the main thread.
    private func checkInstalled() async {
        let versions = await Task.detached(priority: .utility) {
            var versions: [CodingAgent: String?] = [:]
            for agent in CodingAgent.allCases {
                versions[agent] = .some(agent.installedVersion())
            }
            return versions
        }.value
        installed = versions
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
