# Task board — design

Date: 2026-11-27. Builds on the switch-first tracking design (2026-11-26) and brings tasks back, as the main thing on screen. Everything not named here stays as those specs say.

Artboard: https://claude.ai/artifact/Vu1CeHHQPTXE1fD1Lq6vug (iOS board light/dark, gestures, quick add, Progress, Settings, project editor, Desk mode, Live Activity).

## 1. Purpose

Stint is task oriented, not project oriented. The main screen is one column of task cards, like a Trello list. Every card belongs to a project and shows it. Tapping a card is how you switch: it becomes the current card and the Mac tracks its project. Time is still tracked per project only.

## 2. Decisions

| Topic | Decision |
|---|---|
| Card states | Pending, Active, Completed. Any number of Active cards, across projects. |
| Current card | At most one. Tap a card body → it becomes Active (if Pending or Completed) and current; tracking switches to its project. |
| Completing the current card | Tracking stays on the project. No card is current until you tap one. |
| Column order | Active (current first), Pending, Completed today (collapsed). Changing state moves the card. Manual order within a group. |
| Gestures (iOS) | Tap = current. Swipe right = complete. Swipe left = back to Pending (Active only) and Delete. Long-press = Edit title / Change project / Delete; drag reorders within a group. |
| Card content | Title + project (colour stripe, chip with icon or initials and short name). No estimates, no per-task time. |
| Completed cards | Shown until midnight, then off the board (still counted). |
| Quick add | Bottom bar: project chip (defaults to the current card's project, else the tracked project, else the first project), text field, mic (Dictate). Return adds to the top of Pending. |
| iOS navigation | One main screen. No tab bar. Progress and Settings open as sheets from two header buttons. |
| Progress | One scroll: Today (focused, points, cards done, per project), This week (bars vs goal), Rewards (balance, treats), goal history. |
| Settings | Projects (list, new, editor), Desk mode, Account. App/site allowlists and treats stay on the Mac. |
| Desk mode | Kept. Tiles are the Active cards plus Break and Stop. |
| Live Activity | Adds the current card's title under the project. |
| Look | System iOS, light and dark. |
| Mac | Same card model in the menu bar panel and the ⌃⌥Space switcher. Main window unchanged. |

## 3. Data model

One migration (`0012_task_board`), on `public.task` only:

- `active_at timestamptz null`: set when a card becomes Active; cleared by "back to Pending".
- `current_at timestamptz null`: set to now each time a card is tapped (made current).
- `deleted_at timestamptz null`: soft delete. Remote deletes aren't pulled (tombstones are push-only), so a delete is an update every device sees.

State is derived, never stored as an enum:

- **Completed** if `done_at` is set; else **Active** if `active_at` is set; else **Pending**. Deleted rows are ignored everywhere.
- **Current card**: the one non-deleted task with the latest `current_at`, if it is Active and its project is the tracked project. Otherwise there is no current card.

Why this rule: tapping writes only the tapped row, either device can do it, and there is no extra "current task" field to keep consistent with tracking. Completing, sending back to Pending, switching project elsewhere (switcher, suggestion, phone project switch) or stopping each make the rule return nothing, which is exactly "no card is current".

Sort: `sort` orders cards within a group (lower first, then `created_at`). New cards take `min(sort) − 1` so they land on top of Pending. A drag rewrites `sort` for the moved group.

`SwiftData.TaskItem` gains `activeAt`, `currentAt`, `deletedAt` (all optional, defaults nil so the store migrates lightly). `TaskRow` and `Mapping` carry them. `session.first_task_id` stays unused.

## 4. Shared logic (`StintData/Board.swift`)

Pure functions over `[TaskItem]`, used by both apps:

- `Board.make(tasks:trackedProjectID:now:calendar:)` → `active`, `pending`, `doneToday`, `current`.
- `Board.makeCurrent(_:now:)`: `doneAt = nil`, `activeAt ??= now`, `currentAt = now`.
- `Board.complete`, `Board.toPending` (clears `activeAt`), `Board.delete` (sets `deletedAt`), `Board.retitle`, `Board.move(_:to:)` (change project), `Board.add(title:project:in:now:)`, `Board.reorder(_:from:to:)`.
- Each mutation stamps `updatedAt`. The caller saves and asks for a sync.

Tap flow (both apps): `makeCurrent`, save, sync soon; if the card's project isn't the tracked project, switch to it (Mac: `AppState.switchTo`; phone: `.switchTo` command to the Mac). A rejected or unreachable command leaves the card Active and "current" in data, but it doesn't show as current until tracking is on its project.

## 5. iOS

- `RootView`: signed in → `BoardView` (no `TabView`). Deep link to Desk still works.
- `BoardView`: header (weekday + date, "Today", Progress and Settings buttons), Now bar, `List` with three sections, quick-add bar in the bottom safe-area inset.
- Now bar: tracked project icon, name, current card title (or "Focused"/"On break"/"Off task"/"Mac last seen…"), stretch clock, Break/Resume and Stop. Not tracking: "Not tracking — tap a card to start".
- Cards: a rounded card per row (clear row background, no separators). Current card: 2 pt ring in project colour and a "Now" label. Pending stripe at reduced opacity. Completed: check disc, struck-through title, collapsed `Section(isExpanded:)`.
- Swipes: leading full-swipe Complete (green). Trailing: Pending (indigo, Active only), Delete (red, destructive). Completed cards: trailing Delete only; tap reopens as current.
- Long-press context menu: Edit title (alert with field), Change project (submenu), Delete. `onMove` reorders within Active and Pending.
- Quick add: project `Menu` chip (projects + "New project…" opening the editor), `TextField` submit adds, mic opens Dictate in a sheet (existing `DictateView`), becomes Send while text is typed.
- `ProgressSheet` and `SettingsSheet` (each a `NavigationStack` with Done). Settings › Projects → `ProjectEditorView`: name, short name, colour, icon (shared `IconPicker`), weekly/daily hours goals, off-Mac, share page, archive. New project uses the Mac's defaults (next colour, `shareAlias` "Project N").
- Desk mode: Active cards as tiles (title, project chip, "Now" on current), plus Break and Stop. Tap = the tap flow.
- Removed from iOS: `TasksView`, Today/Week/Rewards tabs (their content moves into Progress).

## 6. Mac

- Menu bar panel (`MenuBarView`), 360 pt wide: header (today total · points), Now bar (project, current card title, clock, Break/Resume, Stop), card list (Active, Pending, Completed today collapsed; scrolls past ~420 pt), quick-add row (project menu + field; Return adds), footer (hotkey hint, Open Stint, Quit). Off-task warning and automation notice stay.
- Card row: click = tap flow. Hover shows a complete (✓) button. Right-click: Complete, Back to Pending, Edit title, Change project, Delete. No drag reorder on the Mac (phone only).
- ⌃⌥Space switcher: Active cards first (with project chip), then projects. 1–9 / Return picks: a card runs the tap flow, a project switches only. Filter matches card titles and project names. Double-press flip-back unchanged.
- Main window: unchanged (Today, Projects, Rewards, Friends, Account).
- Live Activity push: `LiveSessionState.taskTitle` = current card title (nil when none). `differs` includes it.
- `AppState` gains `board`, `tap(_ task:)`, `complete`, `toPending`, `delete`, `retitle`, `move`, `add`; each saves and calls `onTasksChanged` (wired to `SyncCoordinator.syncSoon`).

## 7. Live Activity

`LiveSessionState` gains `taskTitle: String?` (optional, so older payloads decode). Lock screen: project line, then task title (one line), then status. Dynamic Island expanded bottom: task title, else status. The phone's local fallback (`LiveActivities.reconcile`) fills it from the same current-card rule.

## 8. Out

- Per-task time, estimates in the UI, notes on cards.
- Drag reorder on the Mac. Drag between groups (use swipes / menu).
- Editing allowlists, treats or break allowance on the phone.
- Mac main-window redesign.

## 9. Testing

- `swift test` (Shared): `BoardTests` — state derivation, current-card rule (latest `current_at`, project must match tracking, completed/pending/deleted give none), today-only completed, ordering and new-on-top, reorder, mutations stamp `updatedAt`. `MappingTests` round-trips the new columns. `LiveSession` decodes a payload without `taskTitle`.
- `supabase test db`: existing pgTAP still passes after the migration.
- `xcodebuild test` for StintMac and StintPhone (existing suites; switcher tests updated for card rows).
- Hand check in the iOS simulator against the local stack: add, tap, swipe, Progress/Settings sheets, Desk.

## 10. Ship

Push migration 0012 to the hosted project. Build Release: Mac (`dev.stint.mac.hosted`) into `/Applications/Stint.app`; iOS onto the iPhone 11. Commit on `main` and push.
