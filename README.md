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

## Tests

Logic: `cd Shared && swift test`. App: the same `xcodebuild` command with `test` instead of `build`.

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
