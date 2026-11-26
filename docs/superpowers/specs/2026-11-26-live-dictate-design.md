# Live Dictate — design

Date: 2026-11-26. Replaces the Dictate text field + separate confirm screen (spec §6.8) with one screen where task rows appear while you speak. Shared by iOS (`iOS/UI/RootView.swift`) and Mac (`Mac/UI/TodayView.swift`) through `SharedUI/DictateView.swift`.

## Behaviour

- Rows appear when you pause: after ~1.2 s with no new words, the whole transcript so far goes to `parse-tasks` (unchanged) and the answer replaces the rows. Corrections ("make that 30 minutes") work because Claude always sees the full take.
- One screen, saved on confirm. Rows are read-only while listening; after Stop they become editable in place (title, project, minutes, checkbox) and "Add N tasks" saves through `VoiceSave`.
- Typing: a keyboard icon swaps the orb for a text box; "Make tasks" fills the same rows. If dictation is unavailable the screen opens in typing mode with the reason shown.
- "Record more" continues the same transcript; the next re-read rebuilds the rows, so Review edits reset. When rows were edited, show "Recording again will re-sort your tasks".

## Screen

Top to bottom:
1. Rows: card per task — title, project chip ("Choose project" in `Theme.warn` if unknown), "~45 min" (dimmer when guessed). New rows animate in at the bottom; list scrolls to them. "Sorting…" while a re-read is in flight.
2. Live caption: last line or two of the transcript, secondary colour, not editable.
3. Bottom bar: keyboard icon (left), listening orb that pulses with mic level and stops on tap (centre), "Add N tasks" when rows exist (right).

States: empty (big mic + hint "Say what you need to do. Name the project if you can."), listening, finishing (final re-read), review (editable rows, mic becomes "Record more"), typing.

## Components

- `SpeechCapture` (SharedUI, exists): adds `level` (0…1) computed from each tap buffer's RMS.
- `ParseGate` (Core, new, pure): `begin(text) -> Int?` returns a request number, or nil when text equals the last sent text; `accept(n) -> Bool` true only for the newest request number.
- `DictateModel` (SharedUI, new, `@Observable`): owns phase, rows (`[DraftTask]`), edited flag, typed text, messages, debounce task. Transcript changes while listening restart a pause timer (default 1.2 s, injectable); on fire → `ParseGate.begin` → `parse(text, projects)` → `VoiceTasks.drafts`. When speech goes idle after Stop → immediate final parse → review. The speech source sits behind a small seam so tests can feed transcripts without the mic.
- `DictateView` (SharedUI): layout only, driven by `DictateModel`.

`parse-tasks`, `VoiceSave`, `VoiceTasks`, and the iOS/Mac hosts are unchanged.

## Errors

- Live re-read fails: keep current rows, show "Couldn't sort — will retry when you pause".
- Final re-read fails with no rows: `VoiceTasks.fallback` (one editable row), today's messages.
- Not signed in (`NotSignedIn`): no live parsing; today's sign-in message; fallback row after Stop.
- Transcript over `VoiceTasks.maxTranscript`: stop sending re-reads, show today's too-long message, keep rows.

## Testing

- Core: `ParseGate` — same text sends once; stale answer rejected; failed newer request doesn't block the next.
- iOS test target: `DictateModel` with fake parse + fake transcript feed — pause → rows; second pause replaces; stale ignored; Stop → final parse → review; failed final with no rows → fallback; edited flag → re-sort note.
- Existing Shared `swift test` and iOS `xcodebuild test` stay green; Mac target builds.
- Device: Release build on iPhone; user retests ~100 words with pauses, edit, add.
