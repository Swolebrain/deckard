# Deckard

## Build & Run

```bash
# Build
xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build

# App location
/Users/gilles/Library/Developer/Xcode/DerivedData/Deckard-hkgvzqxyznptcubawtorcnhugxer/Build/Products/Debug/Deckard.app

# Quit and relaunch (osascript is required — pkill does not work for this app)
osascript -e 'tell application "Deckard" to quit'
open /Users/gilles/Library/Developer/Xcode/DerivedData/Deckard-hkgvzqxyznptcubawtorcnhugxer/Build/Products/Debug/Deckard.app
```

**Always ask for confirmation before restarting Deckard** — do not quit and relaunch the app automatically after a build. Ask the user first.

## Releasing a New Version

Releases are automated via [release-please](https://github.com/googleapis/release-please). Use **conventional commits** (`feat:`, `fix:`, `chore:`, etc.) on `master`.

### How it works

1. Commits land on `master` with conventional commit messages.
2. release-please opens (or updates) a release PR that bumps the version and updates `CHANGELOG.md`.
3. Merging that PR creates a `vX.Y.Z` tag, which triggers the build job to build, sign, and publish the DMG.

### Version locations (managed by release-please)

These files contain `x-release-please-version` annotations and are bumped automatically:

1. `Resources/Info.plist` — `CFBundleShortVersionString`
2. `Sources/Window/SettingsWindow.swift` — version label in About pane

The `README.md` badge version is not managed by release-please (shields.io URL format conflicts with the generic replacer) — update it manually when needed.

Do not bump versions manually — merge the release-please PR instead.

## Commit Messages

Use [Conventional Commits](https://www.conventionalcommits.org/) prefixes:

- `fix:` — bug fix
- `feat:` — new feature
- `refactor:` — code change that neither fixes a bug nor adds a feature
- `chore:` — build, CI, dependencies, tooling
- `docs:` — documentation only

Example: `fix: use length-bounded reads for terminal URL actions (#6)`
