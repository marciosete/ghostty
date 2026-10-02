<h1>
<p align="center">
  <img src="fork/icon/Maggie.png" alt="Maggie" width="128">
  <br>Maggie
</h1>
  <p align="center">
    A macOS terminal for a flock of Claude Code sessions. Built on Ghostty.
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
[Claude Code](https://claude.com/product/claude-code) session in it is doing.
Run a dozen sessions across worktrees, see at a glance which ones are working,
which are waiting on you and which are done, and watch the cost and the token
rate as they go. It is a real terminal underneath: Ghostty's renderer, Ghostty's
config, Ghostty's shell integration.

Maggie is macOS only. It is an independent project and is not affiliated with
Ghostty or Anthropic.

## What it does

**A sidebar of sessions.** Tabs are vertical, named, grouped and searchable. A
session's tab takes the colour of what its Claude Code is doing:

| Colour | Meaning                                                              |
| ------ | -------------------------------------------------------------------- |
| blue   | working on a request                                                 |
| red    | needs you: a permission, a question or a dialog                      |
| yellow | finished, with edits that aren't committed yet                       |
| teal   | committed in its worktree, not yet landed on the main checkout       |
| none   | finished, everything committed and landed                            |

Pick **Auto** to follow Claude Code, **Attention** to only light up when a
session needs you, or any fixed colour. Hover a session for its models, tokens
and cost; an extended row shows its project and what it is doing; a speaker on
the tab reads its last reply aloud.

**A workspace that comes back.** Quit and reopen, and every window, tab, split
and Claude Code session is restored where it was, resumed with `claude --resume`.
New tabs open in their group's folder.

**Worktrees and source control.** A session started with `claude -w` runs in
its own worktree. Maggie follows it: the source control panel shows that
worktree's branch, changes and commits ahead of `main`, and an Auto tab counts
what is left to commit and lands the worktree when it is clean.

**Usage.** A panel with the cost and tokens of every Claude Code session, by
day, project and model, priced at current rates, with your plan's limits
alongside. A custom range for the accountant.

**Reply timing in the titlebar.** The time to first token and the tokens per
second of the reply streaming in the current tab, live.

**Capture.** Turn it on, and the requests Claude Code sends to the model, system
prompt and all, are saved per session, exactly as the API receives them.

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
Maggie to Applications. Every push to `main` becomes a release, so the latest
one is always current.

Once installed, **Maggie › Check for Updates…** gets the next release from
GitHub, and Maggie can check on its own if you let it.

### From source

You need [Zig 0.16](https://ziglang.org/download/), Xcode 26 or newer and
[Claude Code](https://claude.com/product/claude-code). Optionally
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
GitHub release. Versions are semver: `fork/VERSION` holds `MAJOR.MINOR`, and
each push since it last changed counts one patch, so releases run `0.1.0`,
`0.1.1`, … until the file is bumped. The appcast is signed with the key pairing
`fork/sparkle-public.key`; the app accepts no update that isn't.

## How it works

Maggie finds the Claude Code running in each terminal from Claude Code's own
session registry and reads the session's transcript. There are no hooks to
install and nothing to add to your Claude Code settings.

The usage panel is computed from those transcripts, and the plan limits from
what `claude` itself reports.

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
