<h1>
<p align="center">
  <img src="fork/icon/Maggie.png" alt="Maggie" width="128">
  <br>Maggie
</h1>
  <p align="center">
    A macOS terminal for a flock of Claude Code and Codex sessions. Built on Ghostty.
    <br />
    <a href="#what-it-does">What it does</a>
    ·
    <a href="#install">Install</a>
    ·
    <a href="#how-it-works">How it works</a>
    ·
    <a href="#ghostty">Ghostty</a>
    ·
    <a href="#why-maggie">Why Maggie</a>
  </p>
</p>

Maggie is [Ghostty](https://ghostty.org) with a sidebar that knows what every
[Claude Code](https://claude.com/product/claude-code) or
[Codex](https://developers.openai.com/codex/cli) session in it is doing.
Run a dozen sessions across worktrees, see at a glance which ones are working,
which are waiting on you and which are done, and watch the cost and the token
rate as they go. It is a real terminal underneath: Ghostty's renderer, Ghostty's
config, Ghostty's shell integration.

Maggie is macOS only. It is an independent project and is not affiliated with
Ghostty, Anthropic or OpenAI.

## What it does

**A new session is an agent session.** Open a tab, split or window and your
primary agent starts in it: Claude Code or Codex. **Settings…** (⌘,) says
which agents are enabled, either or both, and which is primary. In a git repository it gets its own worktree (`claude -w`, `codex --worktree`),
so what it changes is its own, and a session opened from a worktree starts from
the main checkout, so two never share one. `/exit` drops to the shell and the
tab stays. Turn it off in Settings or under **View › Start … in New Sessions**;
a shell startup file that starts an agent itself can check
`MAGGIE_CLAUDE_CODE_START`, set in these terminals (with `MAGGIE_AGENT` naming
the agent), and stand down.

**Pivot between agents.** A session's menu in the sidebar hands it to the other
agent, in the same worktree: **New Session** starts it fresh, **Continue the
Conversation** writes the conversation so far out as Markdown and starts the
other agent reading it, so Codex picks up where Claude Code left off, or back
again, as often as you like. The old session stays until you close it.

**A sidebar of sessions.** Tabs are vertical, named, grouped and searchable. A
session's tab takes the colour of what its agent is doing:

| Colour | Meaning                                                              |
| ------ | -------------------------------------------------------------------- |
| blue   | working on a request                                                 |
| red    | needs you: a permission, a question or a dialog                      |
| yellow | finished, with edits that aren't committed yet                       |
| teal   | committed in its worktree, not yet landed on the main checkout       |
| none   | finished, everything committed and landed                            |

Pick **Auto** to follow the agent, **Attention** to only light up when a
session needs you, or any fixed colour. Hover a session for its models, tokens
and cost; an extended row shows its project and what it is doing; a speaker on
the tab reads the session's last reply aloud.

**A workspace that comes back.** Quit and reopen, and every window, tab, split
and agent session is restored where it was, resumed with `claude --resume` or
`codex resume`. New tabs open in their group's folder.

**Worktrees and source control.** A session started with `claude -w` or
`codex --worktree` runs in its own worktree. Maggie follows it: the source
control panel shows that worktree's branch, changes and commits ahead of
`main`, and an Auto tab counts what is left to commit and lands the worktree
when it is clean.

**Usage.** A panel with the cost and tokens of every Claude Code and Codex
session, by day, project and model, priced at current rates, with your Claude
and Codex plan limits alongside. A custom range for the accountant.

**Reply timing in the titlebar.** The time to first token and the tokens per
second of the reply streaming in the current tab, live. For a Codex session, the
time to first token and the length of the turn, once it ends.

**Capture.** Turn it on, and the requests Claude Code sends to the model, system
prompt and all, are saved per session, exactly as the API receives them. For
Codex, **Capture Codex Context** saves the session's own record of its context as
it grows, which is Codex's history rather than the request it sends.

**Keep the Mac awake** from the sidebar, lid closed included, while the flock
works.

Everything Ghostty does still works, and Maggie reads your existing
`~/.config/ghostty/config`.

## Install

Maggie installs next to the official Ghostty, under its own name and bundle
ID, with its own preferences and Dock entry. It never updates from Ghostty's
feed.

### Download

Get `Maggie.dmg` from the
[latest release](https://github.com/marciosete/maggie/releases/latest) and drag
Maggie to Applications. Every feature or fix pushed to `main` becomes a
release, so the latest one is always current.

Once installed, **Maggie › Check for Updates…** gets the next release from
GitHub, and Maggie can check on its own if you let it.

### From source

You need [Zig 0.16](https://ziglang.org/download/), Xcode 26 or newer and
[Claude Code](https://claude.com/product/claude-code) or
[Codex](https://developers.openai.com/codex/cli). Optionally
[SwiftLint](https://github.com/realm/SwiftLint), which the build runs if it is
installed, and Python 3 with Pillow to regenerate the icon.

```sh
git clone https://github.com/marciosete/maggie.git
cd maggie
fork/create-signing-identity.sh   # once per Mac; see below
fork/install.sh
```

`fork/install.sh` builds a release app and installs it to `/Applications/Maggie.app`.
Override `DEST` to install elsewhere (`DEST=~/Applications fork/install.sh`).

`fork/create-signing-identity.sh` creates a local certificate to sign the app
with. macOS remembers privacy answers (Photos, Documents, …) per signature, so
without it every reinstall asks again. Skip it and the app is signed ad hoc.

A Maggie installed this way updates from the releases like any other, and also
has **Maggie › Update Maggie from Source…**, which builds the checkout it was
installed from, restarts, and brings every window, tab and session back. It
runs `fork/install.sh --build-only` while you keep working, then
`--install-staged` after Maggie quits.

### Releases

[`.github/workflows/release.yml`](.github/workflows/release.yml) builds every
push to `main` into a universal `Maggie.app`, signs and notarizes it when the
Apple secrets are set, and publishes a zip, a DMG and the Sparkle appcast as a
GitHub release. Versions are semver and the commit messages decide them, as
semantic-release does: a `feat:` is a minor release, a `fix:` or `perf:` a
patch, a breaking change a major, and a push with none of those makes no
release (see [CONTRIBUTING.md](CONTRIBUTING.md)). The release notes are the
commits, grouped. The appcast is signed with the key pairing
`fork/sparkle-public.key`; the app accepts no update that isn't.

## How it works

Maggie finds the Claude Code running in each terminal from Claude Code's own
session registry and reads the session's transcript. It starts Codex with
`--no-daemon`, so each terminal's `codex` owns its session, and with a terminal
title that names the thread, its model and its state; it finds the session from
the rollout file (`~/.codex/sessions/…`) the process keeps open and reads the
turn's state, model and edits off the end of it, and the title says when Codex
is waiting on you. A `codex` started by hand runs through Codex's shared daemon
and isn't followed. There are no hooks to install and nothing to add to either
agent's settings.

The usage panel is computed from those transcripts and rollouts, and the plan
limits from what `claude` and `codex app-server` report.

For the reply timing, new terminals get `ANTHROPIC_BASE_URL` pointed at a local
proxy that passes every request through to Anthropic untouched and watches the
stream go by. It can be turned off from the menu; terminals opened while it is
off talk to Anthropic directly. Capture uses the same kind of proxy and is off
until you turn it on.

Session state is kept in Maggie's own preferences, under its bundle ID, never
in Ghostty's.

## Ghostty

Maggie is a fork of [Ghostty](https://github.com/ghostty-org/ghostty) by
Mitchell Hashimoto and the Ghostty contributors. It shares Ghostty's terminal
core, renderer, fonts, input handling, config and shell integration; the
sidebar, workspace, source control, usage, streaming and capture features are
Maggie's. The GTK app for Linux is unchanged upstream code and is not built or
tested here.

Upstream changes are merged in after each Ghostty release. Ghostty's own
documentation at [ghostty.org/docs](https://ghostty.org/docs) applies to
everything Maggie inherits, and [HACKING.md](HACKING.md) to building it.

Ghostty is a trademark of its owners. Maggie uses its own name and icon, and
describes itself as built on Ghostty. See [NOTICE.md](NOTICE.md).

## Why Maggie

Australians call the Australian magpie a maggie. It sings one of the most
complex songs of any bird, remembers faces, and in spring it swoops anyone who
comes too close to the nest. A red tab in the sidebar is a maggie swooping.

## License

MIT, the same as Ghostty. Copyright © 2024 Mitchell Hashimoto, Ghostty
contributors; changes in this fork © 2026 Marcio Sete, released under the same
license. See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md).
