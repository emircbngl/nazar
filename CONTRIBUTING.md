# Contributing to Nazar

Thanks for considering a contribution. A few ground rules to keep the project healthy.

## ⚠️ Forking & redistributing

If you fork this repo and ship your own build, **you MUST change two things**
in `Nazar/Info.plist` before distributing — otherwise your users' Sparkle
client will silently pull updates from this upstream repo's release feed and
either install upstream binaries (signed by a different team, will fail
verification) or get stuck on stale versions:

1. **`SUFeedURL`** — point at *your* appcast.xml URL, not
   `https://raw.githubusercontent.com/emircbngl/nazar/main/appcast.xml`.
2. **`SUPublicEDKey`** — replace with the public key from *your own*
   `generate_keys` run (`./scripts/sparkle/bin/generate_keys`). Your private
   key signs the DMGs your users download; mismatched keys = rejected updates.

Also bump `CFBundleIdentifier` to something under your own reverse-DNS so
your build doesn't fight Nazar.app's preferences or notarization records.

## Before opening a PR

1. **Open an issue first** for anything non-trivial — features, behavior changes, refactors. A 30-second comment from the maintainer can save you an afternoon of work.
2. **Tiny fixes** (typos, README polish, obvious bugs) — feel free to PR directly.

## Development

```bash
git clone https://github.com/emircbngl/nazar.git
cd nazar
swift build               # debug
swift build -c release    # production
```

For local runs, copy the binary into an app bundle:

```bash
mkdir -p Nazar.app/Contents/MacOS Nazar.app/Contents/Resources
cp .build/debug/Nazar Nazar.app/Contents/MacOS/Nazar
cp Nazar/Info.plist Nazar.app/Contents/Info.plist
cp AppIcon.icns Nazar.app/Contents/Resources/
codesign --force --deep --sign - Nazar.app
open Nazar.app
```

## Style

- **Swift API design guidelines** — semantic names over Hungarian.
- Follow the existing comment style: short paragraphs explaining *why*, not what.
- Indentation: 4 spaces.
- Avoid force-unwraps (`!`) and `try!`. Prefer `try?` with a `Logger.shared.warn(...)`.
- `[weak self]` in any closure that escapes (DispatchQueue.async, Timer, etc.).

## Commits

- Subject ≤ 70 chars, imperative mood ("Fix race in closeAllAppsAndWait", not "Fixed").
- Body explains *why*. Skip the body for trivial changes.
- One logical change per commit. Squash PR review fixups before merge.

## Testing

There is no automated suite yet. Before submitting:

- `swift build -c release` succeeds without warnings.
- The dashboard popover opens and closes cleanly.
- The right-click menu structure isn't broken.
- If you touched cleanup logic, **back up your trash/caches** before testing.

## Translations

Localization lives in `Nazar/Localization.swift`. To add a language:

1. Add a new entry to the `table` dictionary keyed by the BCP-47 language code (e.g. `"de"` for German).
2. Translate every key from `"en"` — partial translations are fine; missing keys fall back to English.
3. Open a PR.

## Security issues

Don't open public issues for security problems. See [SECURITY.md](SECURITY.md).
