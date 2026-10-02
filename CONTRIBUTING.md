# Contributing to Maggie

Thanks for your interest. Maggie is a small project maintained in spare time,
so a few things up front.

## Where things go

- **Terminal behaviour, rendering, config, shell integration**: that is
  Ghostty. Report it to and fix it in
  [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty), and Maggie
  gets it with the next upstream merge. If you aren't sure whether it is
  Ghostty's or Maggie's, try the official Ghostty: if it happens there too, it
  is upstream's.
- **The sidebar, workspace, source control, usage, reply timing, capture,
  speaker, caffeine, the install and update flow**: that is Maggie. Open an
  issue here.

## Issues

Say what you did, what you expected and what happened, with the Maggie version
(**Maggie › About**) and macOS version. For anything about a session's colour or
status, say what Claude Code was doing at the time.

## Pull requests

- Keep each pull request to one change. Small is good.
- Match the surrounding code: Swift in `macos/`, Zig in `src/`. Run
  `swiftlint lint --strict --fix` and `zig fmt .` before pushing.
- Everything in `macos/Sources/Features` that Maggie added has tests in
  `macos/Tests`; add to them when you change behaviour.
- Commit messages are [conventional commits](https://www.conventionalcommits.org),
  and they decide the version: `feat(scope): …` is a minor release,
  `fix(scope): …` or `perf(scope): …` a patch, and a `!` after the type or a
  `BREAKING CHANGE:` footer a major. Anything else (`docs`, `chore`, `ci`,
  `refactor`, `test`) ships with the next release but doesn't cause one. The
  scope names what changed — `sidebar`, `workspace`, `source-control`, `usage`,
  `timing`, `capture`, `speaker`, `install`, `release` — and the subject is a
  sentence about what the person gets, like the ones in the log.

## AI

Maggie is built with Claude Code, and you are welcome to use AI tools too. Two
rules: you must understand and be able to explain every line you submit, and
you must say in the pull request what was AI-assisted. See
[AI_POLICY.md](AI_POLICY.md).

## Merging from upstream

Upstream Ghostty is merged after each Ghostty release, not continuously. If
you are working on something that touches shared files, say so in the issue
so it can be timed around a merge.
