# Stint

A Mac focus app that tracks sessions and checks which site you're on.

## Prerequisites

Xcode 27 and XcodeGen (`brew install xcodegen`).

## Run

```
xcodegen generate && open Stint.xcodeproj
```

Pick the StintMac scheme and press Cmd-R. From the command line:

```
xcodebuild -project Stint.xcodeproj -scheme StintMac -destination 'platform=macOS' -derivedDataPath DerivedData build
```

The app lands in `DerivedData/Build/Products/Debug/Stint.app` when you pass `-derivedDataPath DerivedData` (gitignored); otherwise it goes to Xcode's default DerivedData.

## iPhone

```
xcodegen generate && xcodebuild -project Stint.xcodeproj -scheme StintPhone -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath DerivedData build
xcrun simctl install booted DerivedData/Build/Products/Debug-iphonesimulator/Stint.app
```

The simulator reaches the local stack at 127.0.0.1. Sign in with an email code from Mailpit (http://127.0.0.1:54324). Release builds need the production Supabase values in `project.yml` (empty means "Sync not configured").

## Tests

Logic: `cd Shared && swift test`. App: the same `xcodebuild` command with `test` instead of `build`.

Logs: filter Console by subsystem prefix `dev.stint`.

## Permissions

On first use, macOS asks to let Stint control Safari and Chrome. That permission is needed to read the current tab's domain. Ad-hoc signed builds may ask again after each rebuild.

## Backend (local)

Prerequisites: Docker Desktop running, and `brew install supabase/tap/supabase`.

```
supabase start     # local stack; the first run downloads images
supabase db reset  # re-apply migrations
supabase test db   # run the SQL tests
supabase stop      # stop the stack
```

The hosted project, and linking to it, come in plan 4.

## Share page

`share-site/` is the friends page: one static HTML file that calls `rpc/share_data`.

- Local: run `python3 -m http.server 8787 --bind 127.0.0.1 --directory share-site`, then open `http://127.0.0.1:8787/?t=<token>`.
  The Mac's Debug build makes links to this address.
- `config.js` picks the local stack when served from 127.0.0.1/localhost and the hosted project (vaidmipsctbcgxeescqj) everywhere else.
- Production: GitHub Pages (Settings → Pages → Source: GitHub Actions) publishes `share-site/` on every push
  that touches it, to `https://gilbertvirgo.github.io/productivity/`.
