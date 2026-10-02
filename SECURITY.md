# Security

## Reporting

Email marcio@ai-foundry.au with what you found and how to reproduce it. Please
don't open a public issue for a vulnerability. You'll get a reply within a few
days, and credit in the release that fixes it unless you'd rather not.

Anything in the terminal itself (escape sequence handling, rendering, the
shell integration) is Ghostty's: please follow
[Ghostty's security policy](https://github.com/ghostty-org/ghostty/security/policy)
so it is fixed upstream for everyone, and Maggie gets the fix with its next
merge.

## What Maggie does that a terminal doesn't

Worth knowing when you assess it:

- **It reads Claude Code's files.** Session registry and transcripts under
  `~/.claude`, to show what a session is doing, its cost and its last reply.
  Nothing is sent anywhere; the usage panel prices locally from a rates file it
  downloads.
- **It runs a local proxy.** With reply timing on, new terminals get
  `ANTHROPIC_BASE_URL` pointed at `127.0.0.1`, and the proxy forwards every
  request to Anthropic untouched over TLS, watching the stream for timing.
  With capture on, it also writes the requests to
  `~/Library/Application Support/com.marciosete.maggie/`. Both are off from
  the View menu; capture is off by default.
- **It types into your shell.** A new session gets `claude -w || claude` (or
  `claude --resume …` when restored) typed as if you had, once the shell is
  up. View › Start Claude Code in New Sessions turns that off.
- **It can keep the Mac awake** with the lid closed. That needs
  `pmset -a disablesleep`, so the first time it asks for your password and adds
  a sudoers rule allowing exactly that command for your user; nothing else.
- **Updates** come from this repository's GitHub releases, verified against the
  Sparkle key in `fork/sparkle-public.key`, and the app's code signature.

## Supported versions

The latest release only. Every fix ships as a new release.
