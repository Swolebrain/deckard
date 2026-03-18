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

### Version locations (update all 3)

1. `Resources/Info.plist` — `CFBundleShortVersionString`
2. `Sources/Window/SettingsWindow.swift` — version label in About pane
3. `README.md` — download badge version

### Steps

```bash
# 1. Bump version in all 3 files above

# 2. Commit and push
git add Resources/Info.plist Sources/Window/SettingsWindow.swift README.md
git commit -m "Bump version to X.Y.Z"
git push

# 3. Wait for CI to pass, then create GitHub release (also creates the git tag)
gh release create vX.Y.Z --repo gi11es/deckard --title "vX.Y.Z" --latest --notes "release notes here"
```

Use `git log vPREVIOUS..HEAD --oneline` to summarize changes for release notes.

## Commit Messages

Use [Conventional Commits](https://www.conventionalcommits.org/) prefixes:

- `fix:` — bug fix
- `feat:` — new feature
- `refactor:` — code change that neither fixes a bug nor adds a feature
- `chore:` — build, CI, dependencies, tooling
- `docs:` — documentation only

Example: `fix: use length-bounded reads for terminal URL actions (#6)`
