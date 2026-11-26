# Switch-first tracking — design

Date: 2026-11-26. Replaces the Pomodoro-style session model in the 2026-11-24 design (§6.3, §6.6, and the session parts of §6.4, §6.5, §6.7, §6.9). Everything not named here stays as that spec says.

Mockups: https://claude.ai/artifact/9EpTZaSDz5HDYc3vqtAeUh (menu bar panel, ⌃⌥Space switcher, suggested switch, iPhone Desk mode).

## 1. Purpose

The user hops between projects all day: 2 minutes on a Christian Heritage prompt, 5 minutes of freelance work, an hour of sermon prep. Planned-length sessions fight that. Stint becomes a tracker with **one current project at a time**. Switching is the main action and takes one hotkey chord plus one key, or at most two clicks. App and site checks stay, but being in another project's app is treated as a likely switch, not a failure.

## 2. Scope

**In**
- One current project; switch, break, stop. No planned length, no end-early friction, no "first task".
- Switch surfaces: menu bar panel, global hotkey switcher, suggested switch, iPhone Desk mode.
- Idle and sleep pause the current project and resume it on return.
- Per-project "off-Mac" flag for work away from the computer.
- Project icon (SF Symbol) and short name.
- Hours goals, points and rewards, break allowance, off-task nudges, friends share page: kept.

**Hidden, not deleted** (data and code stay; UI entry points removed)
- Tasks: Tasks tab, Today's tasks, Dictate (Mac and iPhone), tasks-goal fields in the project editor. A later design will bring tasks back around switching.

**Out**
- Concurrent projects. To work on another project, switch to it.
- A timeline of today's stretches, and editing past stretches.
- StandBy / Lock Screen widget switching.
- Customisable hotkey.

## 3. Data model

One migration. A `session` row now means **one unbroken stretch on one project**.

- Switching ends the current stretch and inserts a new one at the same second. Stop ends it with no new row.
- `session.planned_min`: drop `not null`. New stretches leave it null.
- `session.first_task_id`: unused by new stretches.
- `session.end_kind`: allow `switched` and `stopped` as well as `completed` and `early`. The `(ended_at is null) = (end_kind is null)` check stays. Old rows are unchanged and still count.
- `session_event`: unchanged. Idle, sleep, break and off-task events belong to the current stretch.
- `project` gains:
  - `icon text null`: an SF Symbol name from a fixed list (§6.4). Null means initials on the project colour.
  - `short_name text null`: shown in the menu bar. Null means the name, truncated.
  - `off_mac boolean not null default false` (§5.6).
- `session_allow`: no longer written. New stretches check the project's live `project_allow`. Old rows stay for history.
- `session_command.kind`: `switch` (with `project_id`), `stop`, `break_start`, `break_end`. The Mac rejects the old `start` kind as "Update Stint on your phone."

`session_totals`, `close_periods` and `share_data` need no change. They already sum `focused_sec` per `project_id` over sessions by `started_at`, and stretches are sessions.

## 4. Points

The rules in `PointRules` are unchanged, except that `sessionComplete` is no longer awarded.

Rounding each short stretch down would lose time, so points are written from **running daily totals**. When a stretch ends, the Mac computes today's totals across all of today's stretches and writes the difference from what is already written today:

- focus: `floor(focused_today_sec / 60) * perFocusedMinute − focus points already written today`
- off-task: the same, with `offtask_today_sec` and `perOfftaskMinute`
- break over: `floor(break_over_today_sec / 60) * perOverBreakMinute − already written`, where `break_over_today_sec = max(0, break_today_sec − allowance_sec)`

Zero lines are skipped. Thirty 2-minute stretches score the same as one 60-minute stretch. The `point_event.ref_id` stays the ending stretch's id. Day and week goal bonuses are unchanged (`close_periods`).

## 5. Mac behaviour

### 5.1 Tracker (Core, pure)

`Tracker` owns the current stretch:

- `switchTo(projectID, at:)`, `stop(at:)`, `startBreak(at:)`, `endBreak(at:)`, `observe(bundleID:host:at:)`, `tick(at:)`, `setIdle`, `setAsleep`.
- Each stretch runs a `SessionEngine` (planned length, `reachedPlannedLength` and `remainingSec` are removed).
- Every stretch end emits a `StretchResult`: the row, its events and its end kind.
- It remembers the **previous project**, for the hotkey and the switcher's top row.
- Switching during a break ends the break in the old stretch first.
- A stretch started while the Mac is idle begins idle.
- Switching to the current project does nothing.

### 5.2 Midnight split

`tick` notices a local day change (profile timezone). It ends the stretch at local 00:00 (`end_kind = switched`) and opens a new stretch on the same project at 00:00. Day and week sums go by `started_at`, so this keeps overnight time on the right day. Off-Mac stretches **stop** at midnight instead (§5.6).

### 5.3 Idle, sleep, crash

- Idle (5 min no input) and sleep pause the current project through the existing events. Coming back resumes the same stretch. Only Stop ends tracking.
- Crash recovery (`Ledger.recoverOrphans`) closes an orphaned stretch as today, with `end_kind = stopped`, and sends the Live Activity `.end` push.

### 5.4 Switch suggestions

`SwitchSuggester` (Core, pure):

- **Owners** of the frontmost app and tab host are the projects (all active projects, not only the current one) whose allowlist matches them. A domain match beats an app match: if B lists `figma.com` and A lists Safari as an app, Safari on figma.com is owned by B only. Always-allowed apps (Stint, loginwindow, screen saver) have no owner.
- With exactly one owner that isn't the current project, it emits `suggest(project, since)` after the app has been frontmost for **10 s**. `since` is when the app came to the front.
- With zero or several owners, it emits nothing.
- "Stay on X" mutes that app (or domain) until the current stretch ends.

On the Mac:

- When a suggestion fires, the **suggestion panel** (mockup "Suggested switch") replaces the off-task nudge for that app. The 15 s off-task grace runs underneath unchanged.
- **Switch from hh:mm**: switch backdated to `since`. The old stretch ends at `since`. Any off-task event after `since` falls outside the row and accounting ignores it. After switching, the panel shows Undo for 10 s, which restores the old stretch.
- **Stay on X**: mute as above. Off-task counts as today.
- Ignored: the panel stays, and off-task counts from 15 s as today.
- An app or site no project allows gets the existing nudge. Its "It's work: allow" now adds the entry to the current project's `project_allow` permanently, with the reason in `label`.

### 5.5 Off-task checks

On-task means the frontmost app or site is in the **current** project's live allowlist (plus the always-allowed apps). The rest of the 2026-11-24 §6.4 rules (grace, browser rules, unreadable host) are unchanged.

### 5.6 Off-Mac projects

While an `off_mac` project is current, there is no idle detection, no sleep pausing and no off-task checks. Its time counts until you switch or stop. It **stops at midnight** instead of splitting, so a forgotten stretch can't run into the next day. Suggestions still fire if you use the Mac for another project's app.

### 5.7 Breaks

Break pauses the current stretch (`break_start`/`break_end`, as today). Break is unavailable while stopped. The allowance and its notification are unchanged.

## 6. Mac UI

### 6.1 Menu bar title

The current project's icon, `short_name` (else the name truncated to about 12 characters) and its time today, e.g. `CHL 1:42`, with a colour dot. When stopped, it shows only the Stint icon. During a break, it shows "Break" with the allowance left.

### 6.2 Menu bar panel (two clicks)

- "Working on" header with today's total and points.
- One big row per active project: icon, name, "Tracking now" or "Last: …", time today, number key. Clicking a row switches.
- Break (shows the allowance left) and Stop buttons.
- A `⌃⌥Space` hint and "Open Stint".
- `StartSessionControls` and the end-early sheet are deleted.

### 6.3 Hotkey switcher (chord + one key)

- `⌃⌥Space`, registered with Carbon `RegisterEventHotKey`, so no Accessibility permission is needed.
- A floating key `NSPanel`, centred on screen. The previous project is the top row and preselected, so the hotkey followed by Return flips back.
- Rows are numbered 1–9 in panel order. Typing filters by name and short name. S stops, B starts or ends a break, Esc cancels, and clicking a row switches.
- Pressing the hotkey again within 0.4 s switches to the previous project and closes the panel.
- If registration fails (the combination is taken), the menu bar panel shows "Hotkey unavailable" and nothing else changes.

### 6.4 Projects editor

Gains an icon picker (a fixed grid of about 24 SF Symbols: building.columns, briefcase, book, hammer, paintbrush, laptopcomputer, music.note, cross, house, graduationcap, camera, chart.bar, doc.text, envelope, globe, heart, leaf, lightbulb, megaphone, person.2, star, terminal, timer, wrench), a short name field and an "Off-Mac work" toggle with the help line "Idle and off-task checks are off while this project is current." The tasks-goal fields are hidden.

### 6.5 Main window

Today keeps per-project time today and the week bars. "Today's tasks", "Start a session" and the Dictate button are removed from the UI. Projects, Rewards, Friends and Account are unchanged apart from §6.4.

## 7. iPhone

### 7.1 Desk mode

- A full-screen view (mockup "Desk mode") for a phone on a stand. It works in landscape and portrait, on a dark background.
- Header: the current project and its time, today's total and points, and whether the Mac is connected.
- Grid of big tiles: each active project (icon, name, time today), then Break, then Stop. The current tile is filled with its project colour.
- Tapping a tile sends a `session_command`. The tile shows a spinner until the matching stretch or break syncs back. A rejection or a 10 s timeout shakes the tile and shows the reason ("Mac not reachable" and so on). Nothing changes locally until the Mac acts.
- `UIApplication.isIdleTimerDisabled = true` while the view is visible, and reset when it disappears.
- Opens from a Today button and from the Start widget, whose deep link becomes `stint://desk`.

### 7.2 Tabs and Today

- Tabs: Today, Week, Rewards. Tasks and the Dictate button are hidden.
- Today: current project card, time today per project, and the Desk mode button.

### 7.3 Live Activity

- One activity per tracking run, from the first switch out of stopped to Stop, not one per stretch.
- A switch is a push **update** whose content state carries the project name, colour, icon and stretch start. A break shows as paused.
- `push-activity` changes only its content-state shape. The Mac sends `.start` on the first switch, `.update` on every switch or break change, and `.end` on Stop or crash recovery.

## 8. Testing

- **Core unit tests:**
  - `Tracker`: switch, switch to the same project, stop, break across a switch, midnight split, off-Mac stop at midnight, start while idle, previous project.
  - `SwitchSuggester`: single owner after dwell, a glance shorter than dwell, shared app silent, domain beats app, mute until stretch end, always-allowed apps have no owner.
  - `dayPoints`: thirty short stretches score the same as one long one, penalties, no duplicate lines.
- **pgTAP:** `end_kind` accepts `switched`/`stopped`, `planned_min` may be null, new project columns and defaults, and the `session_command` kinds. The existing `session_totals` and `close_periods` tests stay green, which proves the goal maths is unchanged.
- **By hand:**
  - Mac: hotkey and double-press, suggestion accept/undo/stay, menu bar switching, off-Mac project across sleep.
  - iPhone 11: Desk mode switching, the screen staying on, and Live Activity updates on switch.

## 9. Build order

1. Migration and Core (`Tracker`, `SwitchSuggester`, `dayPoints`, `SessionEngine` cleanup), with tests.
2. Mac ledger and `AppState` on `Tracker`: menu bar panel, title, removal of the start and end-early UI.
3. Hotkey switcher.
4. Suggestion panel and the permanent "allow".
5. Projects editor fields (icon, short name, off-Mac), and hiding tasks on the Mac.
6. Phone commands on the Mac, then iPhone Desk mode, tabs and Today.
7. Live Activity per run, and the `push-activity` content shape.
