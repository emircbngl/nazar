# Security Policy

## Reporting a vulnerability

If you've found a security issue in Nazar, **please do not open a public issue**. Instead:

1. Open a [Private Security Advisory](https://github.com/emircbngl/nazar/security/advisories/new) on GitHub, or
2. Email the maintainer directly (see the GitHub profile).

You should expect an acknowledgement within 7 days. Fixes for confirmed issues are typically released within 2–4 weeks, depending on severity.

## What counts as a security issue

- A code path that can be triggered to delete files outside the cleanup boundary (e.g., symlink escape, path traversal, race condition between size calculation and deletion).
- Privilege escalation via the Nazar process.
- Code injection via the `nazar://` URL scheme or `defaults` keys.
- Any way to bypass the destructive-action confirmation dialog from outside the app.

## What's NOT in scope

- Crashes that don't lead to data loss or privilege escalation — open a regular issue for those.
- The `Cmd+Shift+R` (Run) shortcut being guessable — it requires user-installed Nazar + active session.
- The fact that Nazar requires Full Disk Access — that's the whole point.

## Disclosure

Once a fix is shipped, the advisory is made public with credit (unless the reporter requests anonymity).
