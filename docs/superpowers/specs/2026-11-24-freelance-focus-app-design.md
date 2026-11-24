# Freelance focus app — design

Date: 2026-11-24
Status: draft, awaiting review
Artboard: https://claude.ai/artifact/7jLEB3FF9u9ocTp9XV8YCZ (9 screens; this spec is the source of truth where they differ)

## 1. Purpose

A personal tool for one freelancer (the owner) to:

1. Set time and task goals per client/project, per week and per day.
2. Run planned-length work sessions and know whether the time was spent on-task.
3. Make procrastination slightly harder (friction) and focus slightly more rewarding (points → self-defined treats).
4. Capture tasks by voice.
5. Share the week's goals and results with friends through private links.

Single user. Friends are viewers, not users.

## 2. Scope

**In**

- macOS app: menu bar timer + main window (Today, Projects, Tasks, History, Rewards, Friends).
- iOS app: Today, Tasks, Week, Rewards, voice capture; widgets; Live Activity / Dynamic Island.
- Off-task detection on Mac (frontmost app + Safari/Chrome tab domain).
- Friction: 15 s off-task grace then reason prompt; 60 s cooldown + reason to end early; daily break allowance.
- Points ledger and treats.
- Voice → AI-parsed task list with confirm step.
- Friends share page (web), one revocable link per friend.
- Sync between devices via Supabase.

**Out (decided, not deferred by accident)**

- Money: rates, earnings, invoices, CSV export.
- Blocking apps (Mac or iPhone); Screen Time / FamilyControls.
- Tracking work done on the phone; sessions run on the Mac only. The phone can start/stop/break a Mac session remotely.
- Launching apps/URLs on session start.
- Friend accounts, reactions, comments.
- Hour caps (max per project).
- Open-ended stopwatch sessions.
- Streaks.
- Multi-user / onboarding for other people.

## 3. Platforms and stack

| Piece | Tech |
|---|---|
| Mac app | SwiftUI, macOS 14+, `MenuBarExtra` (window style) + `WindowGroup`. Distributed with Developer ID (not Mac App Store) because Apple Events to browsers needs it unsandboxed. |
| iPhone app | SwiftUI, iOS 17.2+ (needed for Live Activity push-to-start). |
| Widgets | WidgetKit extension; interactive buttons via App Intents. |
| Live Activity | ActivityKit; timer drawn with `Text(timerInterval:)` so no per-second pushes. |
| Speech | `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`. |
| Local store | SwiftData on each device; App Group container shared with widget extension. |
| Backend | Supabase: Postgres + Auth (Sign in with Apple) + Realtime + Edge Functions + pg_cron. |
| AI parsing | Claude via an Edge Function (key stays server-side). Model: `claude-haiku-5-5`, structured output via a tool schema. |
| Share page | Static HTML on a static host (Cloudflare Pages or similar) that fetches JSON from an Edge Function. Supabase's default function domain will not serve `text/html`, so the page itself cannot live there. |

Requires a paid Apple Developer account ($99/yr) to keep the iPhone app installed, use push, and sign the Mac app.

## 4. Repository layout

```
App.xcodeproj
Shared/            Swift package "Core": models, goal math, points rules, off-task state machine, week/day boundaries. No UI, no platform APIs. All unit tests live here.
Mac/               Mac app target: menu bar, window, ActivityMonitor (NSWorkspace + AppleScript), idle/sleep detection.
iOS/               iPhone app target: screens, speech capture.
Widgets/           Widget + Live Activity extension.
supabase/
  migrations/      schema, RLS, SQL functions, pg_cron job
  functions/
    parse-tasks/   transcript → tasks (Claude)
    share-data/    token → JSON for the share page
    push-activity/ start/end Live Activity via APNs
share-site/
  index.html       the friends page (one file, no framework)
```

## 5. Data model (Postgres; mirrored in SwiftData)

All rows carry `id uuid`, `user_id uuid`, `created_at`, `updated_at`. RLS on every table: `user_id = auth.uid()`.

- **profile**: `timezone` (IANA, from the Mac), `week_start` (1 = Monday), `break_allowance_min` (60), `display_name` (shown on share page).
- **project**: `name`, `share_alias` (name friends see; defaults to "Project N"), `color`, `weekly_hours_goal numeric null`, `daily_hours_goal numeric null`, `daily_goal_days smallint[]` (ISO weekdays, default Mon–Fri), `tasks_goal int null`, `tasks_goal_period` (`day`|`week`), `shared bool`, `archived_at null`.
- **project_allow**: `project_id`, `kind` (`app`|`domain`), `value` (bundle ID or domain), `label`.
- **task**: `project_id`, `title`, `estimate_min int null`, `estimate_guessed bool`, `done_at null`, `source` (`manual`|`voice`), `sort`.
- **session**: `project_id`, `first_task_id null`, `planned_min`, `started_at`, `ended_at null`, `end_kind` (`completed`|`early`|null), `early_reason null`, `device` (`mac`).
- **session_allow**: snapshot of the allowlist at session start plus per-session additions (`added_mid_session bool`, `reason null`).
- **session_event**: append-only; `session_id`, `at`, `type` (`offtask_start`, `offtask_end`, `break_start`, `break_end`, `idle_start`, `idle_end`, `sleep`, `wake`), `detail jsonb` (app bundle ID, domain, reason).
- **point_event**: append-only ledger; `at`, `delta int`, `kind` (`focus`, `session_complete`, `daily_goal`, `weekly_goal`, `offtask`, `break_over`, `redeem`), `ref_id null`, `note`. Balance = `sum(delta)`.
- **treat**: `name`, `cost int`, `archived_at null`.
- **goal_result**: `project_id`, `period` (`day`|`week`), `period_start date`, `goal_kind` (`hours`|`tasks`), `target numeric`, `actual numeric`, `met bool`. Written once when the period closes; never edited.
- **share_link**: `token text` (32 random bytes, base64url), `friend_label`, `revoked_at null`.
- **device**: `platform`, `apns_token`, `push_to_start_token` (iOS) for Live Activity pushes.

Durations shown in the UI (focused time etc.) are derived from `session` + `session_event`, not stored. A SQL view `session_totals` computes `focused_sec`, `offtask_sec`, `break_sec`, `idle_sec` per session.

## 6. Behaviour

### 6.1 Time boundaries

- Days and weeks are computed in `profile.timezone`. Weeks run Monday 00:00 to Sunday 24:00.
- A session's time is attributed to the day it **started**. Sessions are at most 90 min, so a session crossing midnight is rare; this is accepted.

### 6.2 Goals

Per project, any combination of:

- **Weekly hours**: focused time across the week ≥ target.
- **Daily hours**: on each day in `daily_goal_days`, focused time that day ≥ target. Days not listed have no goal.
- **Tasks done**: tasks of that project with `done_at` in the period ≥ target (period = day or week).

Only **focused** time counts toward hours goals. Off-task, break, and idle time do not.

Periods close via a pg_cron job that runs hourly and closes any day/week that has ended in the owner's timezone and has no `goal_result` yet. Closing writes `goal_result` rows and awards goal points in the same transaction. Late-syncing data (a Mac offline at midnight) after close does not reopen a period. Accepted for a personal tool.

### 6.3 Sessions

- Start needs: project, planned length (25 / 50 / 90 min), first task (optional, picked from that project's open tasks).
- Allowlist = project's allowlist copied into `session_allow`; editable during the session from the menu bar.
- One session at a time, always running on the Mac. It can be started on the Mac directly, or from the phone/widget, which sends a start command the Mac picks up via Realtime (6.11). If the Mac doesn't acknowledge within 10 s, the phone shows "Mac not reachable" and deletes the command.
- The session reaches planned length → it ends as `completed` with a notification and a "start a break?" prompt.
- Focused time accrues only while: not on break, not idle, not asleep, not off-task (after grace, see 6.4).
- Planned length counts **elapsed session time excluding breaks and sleep**. Off-task and idle time still use up the planned length. Drifting does not extend the session.

### 6.4 Off-task detection (Mac)

State machine in `Core` (pure, tested); `Mac/ActivityMonitor` feeds it events.

Inputs:

- Frontmost app changes: `NSWorkspace.didActivateApplicationNotification`.
- While Safari or Chrome is frontmost, poll the active tab URL every 2 s via AppleScript. Needs Automation permission per browser.
- Idle: `CGEventSource.secondsSinceLastEventType` ≥ 5 min → `idle_start`; any input → `idle_end`.
- Sleep/wake: `NSWorkspace.willSleepNotification` / `didWakeNotification`.

Rules:

- **On-task** if frontmost bundle ID is in the session allowlist, OR it is a supported browser and the tab's host equals or is a subdomain of an allowed domain.
- Always on-task: this app itself, `loginwindow`, screen saver, System Settings while a permission prompt is showing.
- A supported browser in the allowlist as an *app* means "all sites allowed". If only domains are listed, the browser is on-task only on those domains.
- Unsupported browsers (Firefox, Arc, etc.) are judged as apps only.
- Going off-task starts a **15 s grace**. Returning within grace logs nothing. After grace, write `offtask_start` (timestamped at the end of grace) and show the nudge panel.
- Nudge panel: shows the culprit (app or domain), the off-task timer, and its point cost. It offers:
  - "What are you doing here?" field
  - **Back to [last on-task app]**: activates that app.
  - **It's work: allow for this session**: needs a reason; adds to `session_allow` with `added_mid_session`, ends the off-task stretch.
- The panel stays up until one of those happens, or the user returns to an on-task app on their own. Typing a reason without choosing logs the reason and keeps counting.
- Tab host unreadable (Automation permission denied, no window): a supported browser counts as on-task if it is app-listed **or** the allowlist has any domain entry; benefit of the doubt. A banner in the menu bar panel says site checks are off until permission is granted.

### 6.5 Breaks

- "Take a break" pauses the session (`break_start`); "Resume" ends it.
- Break minutes come from today's allowance (`profile.break_allowance_min`, default 60).
- When the allowance hits 0 during a break, show a notification. Each further break minute costs points (6.7).
- No break outside a session.

### 6.6 Ending early

- "End early…" opens a sheet with a 60 s countdown and a required reason.
- The "End session" button is disabled until the countdown finishes and the reason is non-empty. "Keep working" closes the sheet.
- Closing the sheet resets the countdown; reopening starts a fresh 60 s.
- Ending early: `end_kind = early`. Focus points for minutes already earned are kept. No completion bonus.

### 6.7 Points

Defaults live in `Core` as constants (one place to tune):

| Event | Points | When written |
|---|---|---|
| Focused minute | +1 | at session end, one row per session |
| Session completed | +10 | at session end |
| Daily hours or tasks goal met | +20 per goal | at day close |
| Weekly hours or tasks goal met | +100 per goal | at week close |
| Off-task minute (after grace) | −2 | at session end, one row per session |
| Over-allowance break minute | −1 | at session end |
| Redeem treat | −cost | on redeem |

- Partial minutes round down.
- "Points today" in the UI is computed live from the running session plus today's ledger rows; the ledger itself is written only at the moments in the table.
- Balance can't go below 0 through redemption: "Redeem" is disabled when cost > balance. Penalties can push the balance negative. That is allowed and shown.

### 6.8 Tasks and voice

- Tasks belong to one project. Created manually, or by voice.
- Voice flow (iPhone; Mac also gets a "Dictate tasks" button using the same flow):
  1. Record with on-device speech recognition; live transcript shown.
  2. Stop → POST transcript + active project names/IDs to `parse-tasks`.
  3. Function calls Claude with a tool schema returning `[{title, project_id|null, estimate_min|null, estimate_guessed}]`. Validate against the schema. Drop items with empty titles.
  4. Confirm screen: each task checked by default; tap to edit title, project, estimate. Guessed estimates labelled "guessed". Unmatched project → "Choose project", required before saving.
  5. "Add N tasks" saves checked items.
- Failures:
  - Speech permission denied → typed text field instead, same flow.
  - Network/AI failure → the transcript becomes one editable task, with an error line.
  - Transcript > 4,000 chars → rejected before sending.

### 6.9 iPhone surfaces

- **App tabs**: Today (running session card, week bars, up next), Tasks, Dictate (centre button), Week (goal history), Rewards.
- **Medium widget**: this week's hours per project vs goal.
- **Small widgets**: "Today" (focused vs today's daily goals total, points today); "Start" (starts a 50 min session on the project furthest behind today's daily goal; App Intent → start request).
- **Live Activity**: starts on the phone when a Mac session starts. Uses push-to-start from `push-activity`, called by DB webhooks:
  - `session` insert → start
  - `session` update setting `ended_at` → end
  - `session_event` insert of `offtask_*`/`break_*` → update
  
  Shows project, countdown, current task, on-task/off-task state.
- Widgets refresh on app foreground and on Realtime updates while running; otherwise via their timeline every 15 min.

### 6.10 Friends share page

- In the Friends section, the owner creates a link per friend (`friend_label` for the owner only) and sends it through the share sheet. Links can be revoked.
- `share-site/index.html?t=<token>` fetches `share-data?t=<token>`. That function looks up a non-revoked token with the service role and returns only:
  - `display_name`, current week dates, last-updated time
  - for each **shared** project: `share_alias`, goals (kind, target, actual so far)
  - status per goal: on track / behind / met / missed
  - daily-goal results Mon–Fri for this week
  - last week's `goal_result` rows
- Never returned: real project names, tasks, apps, domains, reasons, points, session details.
- "On track" = actual ≥ target × (elapsed fraction of period). Otherwise "behind".
- Unknown or revoked token → generic "This link isn't active" page. Same response for both, so tokens can't be probed.
- Page is plain HTML/CSS + one `fetch`. No looping animations.

### 6.11 Sync

- Each device writes locally (SwiftData) first, then pushes to Supabase through an outbox. It pulls via Realtime, plus a full pull on launch.
- Conflicts: last-write-wins on `updated_at` for editable rows (project, task, treat, profile). `session_event` and `point_event` are append-only, so no conflicts.
- The Mac owns running-session state. The phone sends requests (`start`, `break`, `resume`, `end_early_request`) as rows in a `session_command` table that the Mac consumes and deletes.
- End-early from the phone opens the same 60 s cooldown + reason sheet **on the phone**, then sends the command.
- A Mac losing network mid-session keeps running locally and syncs later.

## 7. Permissions the Mac app asks for

| Permission | Why | If denied |
|---|---|---|
| Automation (Safari, Chrome) | read active tab domain | browsers judged as whole apps; banner |
| Notifications | session end, off-task, break allowance | nudge panel still appears; no banners |
| Microphone + Speech | Mac dictation | typed input |

No Accessibility or Screen Recording permission needed.

## 8. Testing

- **`Core` unit tests** (Swift Testing), the main safety net:
  - Off-task state machine: grace in/out, subdomain matching, browser-as-app vs domain-only, mid-session allow, idle/sleep interplay.
  - Session accounting: focused/off-task/break/idle totals from an event list; planned length excludes breaks and sleep.
  - Points calculator from session totals; rounding; negative balance; redeem guard.
  - Period boundaries: timezone, Monday week start, DST change week.
  - Goal evaluation and "on track" fraction.
- **SQL**: one test script for the period-close function on fixture data (pgTAP or a plain `psql` script with asserts).
- **Edge functions**: a Deno test per function; `parse-tasks` with a stubbed Claude response, covering schema validation and the fallback.
- **Manual checklist** per release:
  - Browser permission flow
  - Live Activity start/end
  - Widget refresh
  - Share link revoke

## 9. Build order (for the implementation plan)

1. `Core` package + tests (no UI).
2. Supabase schema, RLS, period-close job.
3. Mac app: projects/goals CRUD, sessions, ActivityMonitor, friction, points, menu bar. Usable on its own with local data.
4. Sync.
5. iPhone app + widgets.
6. Voice + `parse-tasks`.
7. Live Activity + `push-activity`.
8. Share page + `share-data`.

## 10. Open items

- App name (placeholder everywhere).
- Static host for `share-site` (Cloudflare Pages assumed).
- Apple Developer account in place before step 5.
