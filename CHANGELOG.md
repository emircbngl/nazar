# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] — 2026-05-22

### Added
- One-click cleanup pipeline — close apps, clean user caches, system logs, Trash,
  Xcode DerivedData, and temp files, plus optional system update check.
- **Profiles & Shortcuts** — Profile manager with a built-in default profile and
  user-defined profiles, each with its own optional global Carbon hotkey.
- **Protected Apps** — Always-protect and one-time-protect lists.
- **Startup Apps** — Apps that auto-relaunch after cleanup.
- **Custom folders** with per-folder age filters (7d, 30d, 90d, 6mo, 1y).
- **Dashboard** with disk usage, running apps, and available updates.
- **`nazar://` URL scheme** — `cleanup`, `dashboard`, `profiles`, `feedback`.
- **Local logger** rolling at 256 KB, attached to feedback reports.
- **Async-signal-safe crash handler** for SIGSEGV/ABRT/BUS/ILL/FPE/PIPE.
- **Permission deep links** to relevant System Settings panes.
- **Localization**: English and Turkish.
- **Trigger modes**: double-tap, double-click, ⌥-click, long press.
- **Feedback dialog** with system info + log tail.
- **Confirmation dialog** before destructive operations (toggleable).

### Privacy
- No network calls. No telemetry. No analytics.
- Log file is local-only at `~/Library/Application Support/Nazar/nazar.log`.

[Unreleased]: https://github.com/emircbngl/nazar/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/emircbngl/nazar/releases/tag/v1.0.0
