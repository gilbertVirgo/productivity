# Goal Sharing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Friends open a private link and see this week's goals and results for the projects the owner shares. The owner creates and revokes those links from the Mac's new Friends section.

**Architecture:**
- A `security definer` Postgres function, `share_data(token)`, turns a token into the JSON for the share page.
- The static page (`share-site/index.html`, deployed to GitHub Pages) calls it through PostgREST `rpc/share_data` with the public anon key.
- The Mac lists, creates and revokes `share_link` rows over the user's own session (RLS), and hands each link to the share sheet.

**Tech Stack:** Postgres/plpgsql + pgTAP, plain HTML/CSS/JS (no framework, no build), SwiftUI (macOS), supabase-swift 2.55, GitHub Actions Pages.

**Spec:** `docs/superpowers/specs/2026-11-24-freelance-focus-app-design.md` §6.10 (Friends share page), §8 ("Mirror Core": the share-data tests port `GoalsTests`).

## Global Constraints

- The share page returns only:
  - `display_name`, the current week's dates and a last-updated time;
  - for each **shared** project: `share_alias`, its goals (kind, target, actual so far) and each goal's status (on track / behind / met / missed);
  - this week's daily-goal results;
  - last week's `goal_result` rows.
- The share page never returns real project names, tasks, apps, domains, reasons, points or session details.
- "On track" = actual ≥ target × (elapsed fraction of the period). Otherwise "behind".
- An unknown or revoked token gets the generic "This link isn't active" page. Both give the same response, so tokens can't be probed.
- The page is plain HTML/CSS plus one `fetch`, with no looping animations.
- `share_link.friend_label` is shown to the owner only.
- Week = ISO week starting Monday, in `profile.timezone`. This matches `close_periods`.
- Hours actuals use `focused_sec` of **ended** sessions only. This matches `close_periods`.
- Never run `supabase db reset`: the local DB holds test accounts. Apply migrations with `supabase migration up`.
- SwiftPM: `cd Shared && swift test --disable-sandbox` (the flag is mandatory). Swift 6 strict concurrency.
- Work on `main`. No branches or pushes.

**Rulings baked into this plan (spec deviations):**
- **No `share-data` edge function. The page calls a Postgres function through PostgREST.**
  - Spec §6.10 has an edge function that uses the service role. A `security definer` function does the same lookup without a service key in any runtime. The page needs only the public anon key, which already ships in the apps.
  - The spec's reason for a separate host still holds: the page itself is static on GitHub Pages.
  - Cost if wrong: a roughly 10-line edge function that forwards to the same SQL function.
- **Goal math lives in SQL, so `GoalsTests` is ported to pgTAP rather than TypeScript** (§8 "Mirror Core").
- **This week's daily results are computed live from `session_totals`, not read from `goal_result`.**
  - A day closes only at 02:05 the next morning, so recent days would otherwise show no result.
  - Live and closed results differ only when a session syncs late.
  - Last week comes from `goal_result`, which is the record.
- **Daily results cover the project's `daily_goal_days`** (default Mon–Fri), not a fixed Mon–Fri. Future days show `upcoming`.
- **Share page host: GitHub Pages**, deployed by an Actions workflow (decided 2026-11-25; spec assumed Cloudflare Pages). The user enables Pages (Settings → Pages → Source: GitHub Actions) and pushes. Neither happens in this plan.
- **Friends UI is Mac-only.** The spec lists Friends only in the Mac main window.
- The page reads its API URL and anon key from `share-site/config.js`. It is committed with the local stack values, and the user edits it for production.

---

## File Structure

- `supabase/migrations/20261126000009_share_data.sql` holds `goal_status`, `share_data_at` (testable clock) and `share_data` (anon entry point).
- `supabase/tests/06_share_data_test.sql` holds the `GoalsTests` port plus `share_data` fixtures.
- `share-site/index.html` is the friends page.
- `share-site/config.js` holds the API URL and anon key.
- `.github/workflows/share-site.yml` deploys `share-site/` to GitHub Pages.
- `.claude/launch.json` runs a local static server for checking the page.
- `Shared/Sources/StintData/Sync/ShareLinks.swift` holds `ShareLinkRow` plus the `SyncEngine` list/create/revoke methods.
- Tests for it: `Shared/Tests/StintDataTests/ShareLinkTests.swift` (unit) and `SyncIntegrationTests.swift` (one new test).
- `Mac/UI/FriendsView.swift` is the Friends section. It is wired up through `Mac/UI/MainWindow.swift`, `Mac/App/SyncCoordinator.swift` and `project.yml` (`StintShareURL`).

---

### Task 1: `share_data` SQL function

**Files:**
- Create: `supabase/migrations/20261126000009_share_data.sql`
- Test: `supabase/tests/06_share_data_test.sql`

**Interfaces:**
- Produces:
  - `public.goal_status(p_target numeric, p_actual numeric, p_elapsed numeric, p_closed boolean) returns text`, returning one of `met | missed | on_track | behind`.
  - `public.share_data(p_token text) returns jsonb`, executable by `anon`. It returns SQL `NULL` (JSON `null` over REST) for an unknown, revoked or malformed token.
  - JSON shape (Task 2 renders it):

```json
{
  "display_name": "Gil",
  "week_start": "2026-11-23", "week_end": "2026-11-29",
  "updated_at": "2026-11-25T09:30:00+00:00",
  "projects": [{
    "alias": "Client A",
    "goals": [{"kind": "hours", "target": 4, "actual": 2.0, "status": "on_track"},
              {"kind": "tasks", "target": 2, "actual": 1, "status": "on_track"}],
    "days":  [{"date": "2026-11-23", "kind": "hours", "target": 1, "actual": 1.0, "status": "met"},
              {"date": "2026-11-26", "kind": "hours", "target": 1, "actual": null, "status": "upcoming"}],
    "last_week": [{"period": "week", "period_start": "2026-11-16", "kind": "hours", "target": 4, "actual": 3.50, "met": false}]
  }]
}
```

- [ ] **Step 1: Write the failing test** `supabase/tests/06_share_data_test.sql`:

```sql
begin;
select plan(18);

-- GoalsTests port (Shared/Tests/CoreTests/GoalsTests.swift): Swift and SQL must agree.
select is(public.goal_status(12, 12.4, 0.6, false), 'met', 'met before period ends');
select is(public.goal_status(4, 2.5, 1, true), 'missed', 'missed when closed short');
select is(public.goal_status(12, 6, 0.5, false), 'on_track', 'on track at pace');
select is(public.goal_status(12, 5.9, 0.5, false), 'behind', 'behind pace');
select is(public.goal_status(12, 0, 0, false), 'on_track', 'nothing due yet');

insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000c1', 'share@test.local');
update public.profile set timezone = 'Europe/London', display_name = 'Gil'
 where user_id = '00000000-0000-0000-0000-0000000000c1';

-- Shared: weekly 4 h, daily 1 h (Mon–Fri), 2 tasks/week. Not shared: Hidden.
insert into public.project (id, user_id, name, share_alias, shared, created_at, weekly_hours_goal, daily_hours_goal, tasks_goal, tasks_goal_period)
values ('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000c1', 'Northwind Secret', 'Client A', true,
        '2026-11-01', 4, 1, 2, 'week'),
       ('20000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000c1', 'Hidden', 'Other', false,
        '2026-11-01', 4, 1, null, 'week');

create function pg_temp.sess(pid text, s timestamptz, mins int, ended boolean default true)
returns void language sql as $$
  insert into public.session (user_id, project_id, planned_min, started_at, ended_at, end_kind)
  values ('00000000-0000-0000-0000-0000000000c1', pid::uuid, mins, s,
          case when ended then s + make_interval(mins => mins) end,
          case when ended then 'completed' end) $$;

-- "Now" is Wed 25 Nov 12:00 London (= UTC in November). Week: Mon 23 – Sun 29.
select pg_temp.sess('20000000-0000-0000-0000-000000000001', '2026-11-23 09:00+00', 60);        -- Mon: met
select pg_temp.sess('20000000-0000-0000-0000-000000000001', '2026-11-24 09:00+00', 30);        -- Tue: missed
select pg_temp.sess('20000000-0000-0000-0000-000000000001', '2026-11-25 09:00+00', 30);        -- Wed: 0.5 of 1 h at half-day → on track
select pg_temp.sess('20000000-0000-0000-0000-000000000001', '2026-11-25 10:00+00', 45, false); -- running: excluded
select pg_temp.sess('20000000-0000-0000-0000-000000000002', '2026-11-23 09:00+00', 120);       -- Hidden project
insert into public.task (user_id, project_id, title, done_at) values
  ('00000000-0000-0000-0000-0000000000c1', '20000000-0000-0000-0000-000000000001', 'secret task title', '2026-11-24 10:00+00');
insert into public.goal_result (user_id, project_id, period, period_start, goal_kind, target, actual, met) values
  ('00000000-0000-0000-0000-0000000000c1', '20000000-0000-0000-0000-000000000001', 'week', '2026-11-16', 'hours', 4, 3.50, false),
  ('00000000-0000-0000-0000-0000000000c1', '20000000-0000-0000-0000-000000000001', 'day', '2026-11-20', 'hours', 1, 1.20, true),
  ('00000000-0000-0000-0000-0000000000c1', '20000000-0000-0000-0000-000000000001', 'day', '2026-11-13', 'hours', 1, 1.00, true),
  ('00000000-0000-0000-0000-0000000000c1', '20000000-0000-0000-0000-000000000002', 'week', '2026-11-16', 'hours', 4, 5.00, true);

insert into public.share_link (user_id, token, friend_label, revoked_at) values
  ('00000000-0000-0000-0000-0000000000c1', repeat('a', 43), 'Sam', null),
  ('00000000-0000-0000-0000-0000000000c1', repeat('b', 43), 'Old', '2026-11-20');

create function pg_temp.share() returns jsonb language sql as $$
  select public.share_data_at(repeat('a', 43), '2026-11-25 12:00+00') $$;

select is(public.share_data_at(repeat('z', 43), '2026-11-25 12:00+00'), null, 'unknown token → null');
select is(public.share_data_at(repeat('b', 43), '2026-11-25 12:00+00'), null, 'revoked token → null (same as unknown)');
select is(public.share_data_at('nope', '2026-11-25 12:00+00'), null, 'malformed token → null');

select is(pg_temp.share() ->> 'display_name', 'Gil', 'display name');
select is((pg_temp.share() ->> 'week_start', pg_temp.share() ->> 'week_end')::text, '(2026-11-23,2026-11-29)', 'ISO week in profile timezone');
select is(jsonb_array_length(pg_temp.share() -> 'projects'), 1, 'only shared projects');
select is(pg_temp.share() #>> '{projects,0,alias}', 'Client A', 'alias, not the real name');
select ok(pg_temp.share()::text !~ '(Northwind|Hidden|secret task|Sam|Old)', 'no names, tasks or friend labels leak');

-- Week: 2 h of 4 at 2.5/7 elapsed (needs 1.43) → on track; 1 task of 2 (needs 0.71) → on track.
select is((select string_agg(g ->> 'kind' || ':' || (g ->> 'actual')::numeric || ':' || (g ->> 'status'), ',')
             from jsonb_array_elements(pg_temp.share() #> '{projects,0,goals}') g),
  'hours:2.0:on_track,tasks:1:on_track', 'weekly goals with live actuals and status');
select is((select string_agg((d ->> 'date') || '=' || (d ->> 'status'), ',')
             from jsonb_array_elements(pg_temp.share() #> '{projects,0,days}') d),
  '2026-11-23=met,2026-11-24=missed,2026-11-25=on_track,2026-11-26=upcoming,2026-11-27=upcoming',
  'daily results on goal days only; today in progress; future upcoming');
select is((select string_agg((r ->> 'period') || ':' || (r ->> 'period_start') || ':' || (r ->> 'met'), ',')
             from jsonb_array_elements(pg_temp.share() #> '{projects,0,last_week}') r),
  'week:2026-11-16:false,day:2026-11-20:true', 'last week from goal_result, this project only');

select ok(has_function_privilege('anon', 'public.share_data(text)', 'execute'), 'anon can call share_data');
select ok(not has_function_privilege('anon', 'public.share_data_at(text, timestamptz)', 'execute'), 'anon cannot pick the clock');

select * from finish();
rollback;
```

- [ ] **Step 2: Run it and confirm it fails.** Run `supabase test db`. Expected: `06_share_data_test.sql` FAILS with `function public.goal_status(...) does not exist`, while the other test files still pass.

- [ ] **Step 3: Write the migration** `supabase/migrations/20261126000009_share_data.sql`:

```sql
-- Friends share page (spec §6.10). The static page calls rpc/share_data with the public anon key;
-- security definer stands in for the spec's service-role edge function. Returns only aliases, goals and results.

-- Port of Core.goalStatus (Shared/Sources/Core/Goals.swift). Keep the two in lockstep (spec §8).
create function public.goal_status(p_target numeric, p_actual numeric, p_elapsed numeric, p_closed boolean)
returns text language sql immutable as $$
  select case when p_actual >= p_target then 'met'
              when p_closed then 'missed'
              when p_actual >= p_target * p_elapsed then 'on_track'
              else 'behind' end
$$;

create function public.share_data_at(p_token text, p_now timestamptz)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  uid uuid;
  tz text;
  shown text;
  today date;
  wk date;
  w0 timestamptz;
  w1 timestamptz;
  elapsed numeric;
  p public.project;
  n int := 0;
  d date;
  d0 timestamptz;
  d1 timestamptz;
  day_elapsed numeric;
  secs numeric;
  cnt int;
  goals jsonb;
  days jsonb;
  projects jsonb := '[]';
begin
  -- Unknown, revoked and malformed tokens all return null: the page can't tell them apart.
  if p_token is null or p_token !~ '^[A-Za-z0-9_-]{43}$' then return null; end if;
  select user_id into uid from share_link where token = p_token and revoked_at is null;
  if uid is null then return null; end if;
  select timezone, display_name into tz, shown from profile where user_id = uid;

  today := (p_now at time zone tz)::date;
  wk := date_trunc('week', today)::date;
  w0 := wk::timestamp at time zone tz;
  w1 := (wk + 7)::timestamp at time zone tz;
  elapsed := extract(epoch from p_now - w0) / extract(epoch from w1 - w0);

  for p in select * from project where user_id = uid and shared and archived_at is null order by created_at, id loop
    n := n + 1;

    goals := '[]';
    if p.weekly_hours_goal is not null then
      select coalesce(sum(focused_sec), 0) into secs from session_totals
       where project_id = p.id and ended_at is not null and started_at >= w0 and started_at < w1;
      goals := goals || jsonb_build_object('kind', 'hours', 'target', p.weekly_hours_goal,
        'actual', round(secs / 3600.0, 1), 'status', goal_status(p.weekly_hours_goal * 3600, secs, elapsed, false));
    end if;
    if p.tasks_goal is not null and p.tasks_goal_period = 'week' then
      select count(*) into cnt from task where project_id = p.id and done_at >= w0 and done_at < w1;
      goals := goals || jsonb_build_object('kind', 'tasks', 'target', p.tasks_goal,
        'actual', cnt, 'status', goal_status(p.tasks_goal, cnt, elapsed, false));
    end if;

    days := '[]';
    for d in select g::date from generate_series(wk, wk + 6, interval '1 day') g loop
      continue when not (extract(isodow from d)::smallint = any (p.daily_goal_days));
      d0 := d::timestamp at time zone tz;
      d1 := (d + 1)::timestamp at time zone tz;
      day_elapsed := least(1, greatest(0, extract(epoch from p_now - d0) / extract(epoch from d1 - d0)));
      if p.daily_hours_goal is not null then
        if d > today then
          days := days || jsonb_build_object('date', d, 'kind', 'hours', 'target', p.daily_hours_goal,
                                             'actual', null, 'status', 'upcoming');
        else
          select coalesce(sum(focused_sec), 0) into secs from session_totals
           where project_id = p.id and ended_at is not null and started_at >= d0 and started_at < d1;
          days := days || jsonb_build_object('date', d, 'kind', 'hours', 'target', p.daily_hours_goal,
            'actual', round(secs / 3600.0, 1),
            'status', goal_status(p.daily_hours_goal * 3600, secs, day_elapsed, d < today));
        end if;
      end if;
      if p.tasks_goal is not null and p.tasks_goal_period = 'day' then
        if d > today then
          days := days || jsonb_build_object('date', d, 'kind', 'tasks', 'target', p.tasks_goal,
                                             'actual', null, 'status', 'upcoming');
        else
          select count(*) into cnt from task where project_id = p.id and done_at >= d0 and done_at < d1;
          days := days || jsonb_build_object('date', d, 'kind', 'tasks', 'target', p.tasks_goal,
            'actual', cnt, 'status', goal_status(p.tasks_goal, cnt, day_elapsed, d < today));
        end if;
      end if;
    end loop;

    projects := projects || jsonb_build_object(
      'alias', coalesce(nullif(p.share_alias, ''), 'Project ' || n),
      'goals', goals,
      'days', days,
      'last_week', coalesce((
        select jsonb_agg(jsonb_build_object('period', period, 'period_start', period_start, 'kind', goal_kind,
                                            'target', target, 'actual', actual, 'met', met)
                         order by period desc, period_start, goal_kind)
          from goal_result
         where project_id = p.id
           and ((period = 'week' and period_start = wk - 7)
             or (period = 'day' and period_start >= wk - 7 and period_start < wk))), '[]'));
  end loop;

  return jsonb_build_object(
    'display_name', shown,
    'week_start', wk,
    'week_end', wk + 6,
    'updated_at', (select max(s.updated_at) from session s join project pr on pr.id = s.project_id
                    where s.user_id = uid and pr.shared and pr.archived_at is null),
    'projects', projects);
end $$;

-- The page's entry point: the clock is always now().
create function public.share_data(p_token text)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select public.share_data_at(p_token, now())
$$;

revoke execute on function public.share_data_at(text, timestamptz) from public, anon, authenticated;
revoke execute on function public.share_data(text) from public;
grant execute on function public.share_data(text) to anon, authenticated;
```

- [ ] **Step 4: Apply the migration and run the tests.** Run `supabase migration up`, then `supabase test db`. Expected: every file passes, including `06_share_data_test.sql .. ok` (18). If an expected string differs only in number formatting (for example `2` vs `2.0`), fix the SQL so it emits what the test expects, rather than editing the test. Do NOT run `supabase db reset`.

- [ ] **Step 5: Smoke test over REST as anon.**

```bash
curl -s -X POST http://127.0.0.1:54321/rest/v1/rpc/share_data \
  -H "apikey: $(supabase status -o env | sed -n 's/^ANON_KEY="\(.*\)"/\1/p')" \
  -H 'Content-Type: application/json' -d '{"p_token":"nope"}'
```

Expected: `null`.

- [ ] **Step 6: Commit.**

```bash
git add supabase/migrations/20261126000009_share_data.sql supabase/tests/06_share_data_test.sql
git commit -m "feat(db): share_data for the friends page"
```

---

### Task 2: Share page and its deploy

**Files:**
- Create: `share-site/index.html`, `share-site/config.js`, `.github/workflows/share-site.yml`, `.claude/launch.json`
- Modify: `README.md` (add a "Share page" section)

**Interfaces:**
- Consumes: `POST {api}/rest/v1/rpc/share_data` with body `{"p_token": "<t>"}` and headers `apikey`/`Authorization: Bearer` set to the anon key. The JSON shape is in Task 1.
- Produces: the page URL `index.html?t=<token>`. The Mac (Task 4) builds `<StintShareURL>?t=<token>`.

- [ ] **Step 1: Write `share-site/config.js`.** It uses the local stack's anon key: the well-known public demo key, also in `project.yml`.

```js
// API for the friends page. Local stack values; for production set your project's URL and anon (public) key.
window.STINT = {
  api: "http://127.0.0.1:54321",
  key: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0"
};
```

- [ ] **Step 2: Write `share-site/index.html`.** All data goes in through `textContent`, never `innerHTML`, because the alias and display name are user-written.

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<meta name="robots" content="noindex">
<title>Stint</title>
<style>
  :root { --bg: #f6f5f2; --card: #fff; --ink: #1d1d1b; --muted: #6b6a66; --line: #e4e2dc;
          --met: #0f7b6c; --on: #2f6fd6; --behind: #b25b00; --missed: #b3261e; }
  @media (prefers-color-scheme: dark) {
    :root { --bg: #161615; --card: #20201e; --ink: #ecebe7; --muted: #9a9892; --line: #33322f;
            --met: #3fb8a6; --on: #7aa7f0; --behind: #e39a4a; --missed: #ef7d74; }
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--ink);
         font: 16px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  main { max-width: 640px; margin: 0 auto; padding: 32px 20px 48px; }
  h1 { font-size: 28px; margin: 0 0 4px; }
  .sub { color: var(--muted); margin: 0 0 24px; }
  .card { background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 18px 20px; margin-bottom: 16px; }
  h2 { font-size: 19px; margin: 0 0 12px; }
  h3 { font-size: 13px; text-transform: uppercase; letter-spacing: .04em; color: var(--muted); margin: 18px 0 8px; }
  .goal { display: flex; justify-content: space-between; gap: 12px; padding: 6px 0; border-top: 1px solid var(--line); }
  .goal:first-of-type { border-top: 0; }
  .bar { height: 6px; background: var(--line); border-radius: 3px; overflow: hidden; margin: 2px 0 8px; }
  .bar > span { display: block; height: 100%; background: currentColor; }
  .days { display: flex; flex-wrap: wrap; gap: 8px; }
  .day { flex: 1 1 64px; text-align: center; border: 1px solid var(--line); border-radius: 10px; padding: 8px 4px; font-size: 14px; }
  .day b { display: block; font-size: 12px; color: var(--muted); font-weight: 600; }
  .met { color: var(--met); } .on_track { color: var(--on); } .behind { color: var(--behind); }
  .missed { color: var(--missed); } .upcoming { color: var(--muted); }
  .empty { text-align: center; padding: 80px 0; color: var(--muted); }
</style>
<script src="config.js"></script>
</head>
<body>
<main id="app"><p class="empty">Loading…</p></main>
<script>
const STATUS = { met: "Met", on_track: "On track", behind: "Behind", missed: "Missed", upcoming: "—" };
const app = document.getElementById("app");

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
}
function message(text) { app.replaceChildren(el("p", "empty", text)); }
function day(iso) { return new Date(iso + "T12:00:00Z"); }
function fmt(d, opts) { return d.toLocaleDateString(undefined, { timeZone: "UTC", ...opts }); }
function amount(kind, v) { return kind === "hours" ? `${Number(v).toFixed(1)} h` : `${v} ${v === 1 ? "task" : "tasks"}`; }
function goalName(kind, period) { return `${kind === "hours" ? "Hours" : "Tasks"} ${period === "day" ? "that day" : "this week"}`; }

function render(data) {
  const name = data.display_name || "Stint";
  const nodes = [
    el("h1", null, `${name}'s week`),
    el("p", "sub", `${fmt(day(data.week_start), { day: "numeric", month: "short" })} – ${fmt(day(data.week_end), { day: "numeric", month: "short" })}` +
      (data.updated_at ? ` · updated ${new Date(data.updated_at).toLocaleString(undefined, { weekday: "short", hour: "numeric", minute: "2-digit" })}` : ""))
  ];
  if (!data.projects.length) nodes.push(el("p", "empty", "Nothing shared yet."));
  for (const p of data.projects) {
    const card = el("section", "card");
    card.append(el("h2", null, p.alias));
    for (const g of p.goals) {
      const row = el("div", "goal");
      row.append(el("span", null, `${goalName(g.kind, "week")}: ${amount(g.kind, g.actual)} of ${amount(g.kind, g.target)}`),
                 el("span", g.status, STATUS[g.status]));
      const bar = el("div", "bar " + g.status), fill = el("span");
      fill.style.width = Math.min(100, (g.actual / g.target) * 100) + "%";
      bar.append(fill);
      card.append(row, bar);
    }
    if (p.days.length) {
      card.append(el("h3", null, "Daily goals"));
      const days = el("div", "days");
      for (const d of p.days) {
        const cell = el("div", "day " + d.status);
        cell.append(el("b", null, fmt(day(d.date), { weekday: "short" })), document.createTextNode(STATUS[d.status]));
        cell.title = d.actual == null ? "" : `${amount(d.kind, d.actual)} of ${amount(d.kind, d.target)}`;
        days.append(cell);
      }
      card.append(days);
    }
    if (p.last_week.length) {
      card.append(el("h3", null, "Last week"));
      for (const r of p.last_week) {
        const row = el("div", "goal");
        const when = r.period === "week" ? goalName(r.kind, "week").replace("this week", "for the week")
                                         : `${fmt(day(r.period_start), { weekday: "short" })} · ${goalName(r.kind, "day")}`;
        row.append(el("span", null, `${when}: ${amount(r.kind, r.actual)} of ${amount(r.kind, r.target)}`),
                   el("span", r.met ? "met" : "missed", r.met ? "Met" : "Missed"));
        card.append(row);
      }
    }
    nodes.push(card);
  }
  app.replaceChildren(...nodes);
  document.title = `${name}'s week · Stint`;
}

const token = new URLSearchParams(location.search).get("t");
if (!token) {
  message("This link isn't active.");
} else {
  fetch(`${STINT.api}/rest/v1/rpc/share_data`, {
    method: "POST",
    headers: { "Content-Type": "application/json", apikey: STINT.key, Authorization: `Bearer ${STINT.key}` },
    body: JSON.stringify({ p_token: token })
  })
    .then(r => { if (!r.ok) throw new Error(r.status); return r.json(); })
    .then(data => data ? render(data) : message("This link isn't active."))
    .catch(() => message("Couldn't load this page. Try again later."));
}
</script>
</body>
</html>
```

- [ ] **Step 3: Write `.claude/launch.json`** for checking the page locally.

```json
{
  "version": "0.0.1",
  "configurations": [
    { "name": "share-site", "runtimeExecutable": "python3",
      "runtimeArgs": ["-m", "http.server", "8787", "--bind", "127.0.0.1", "--directory", "share-site"], "port": 8787 }
  ]
}
```

- [ ] **Step 4: Write `.github/workflows/share-site.yml`.**

```yaml
name: share-site
on:
  push:
    branches: [main]
    paths: ["share-site/**", ".github/workflows/share-site.yml"]
  workflow_dispatch:
permissions:
  contents: read
  pages: write
  id-token: write
concurrency:
  group: pages
  cancel-in-progress: true
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deploy.outputs.page_url }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/upload-pages-artifact@v3
        with:
          path: share-site
      - id: deploy
        uses: actions/deploy-pages@v4
```

- [ ] **Step 5: Append to `README.md`.**

```markdown
## Share page

`share-site/` is the friends page: one static HTML file that calls `rpc/share_data`.

- Local: run `python3 -m http.server 8787 --bind 127.0.0.1 --directory share-site`, then open `http://127.0.0.1:8787/?t=<token>`.
  The Mac's Debug build makes links to this address.
- Production: set `share-site/config.js` to the hosted project's URL and anon key, enable GitHub Pages
  (Settings → Pages → Source: GitHub Actions), and push. The workflow publishes `share-site/` to
  `https://gilbertvirgo.github.io/productivity/`.
```

- [ ] **Step 6: Check the empty and bad-token states by hand.** Start the static server and open `http://127.0.0.1:8787/` (no `t`), then `http://127.0.0.1:8787/?t=nope`. Expected: both say "This link isn't active." The controller checks the populated page after Task 4.

- [ ] **Step 7: Commit.**

```bash
git add share-site .github/workflows/share-site.yml .claude/launch.json README.md
git commit -m "feat(share): friends page and GitHub Pages deploy"
```

---

### Task 3: Share links in StintData

**Files:**
- Create: `Shared/Sources/StintData/Sync/ShareLinks.swift`
- Test: `Shared/Tests/StintDataTests/ShareLinkTests.swift`
- Modify: `Shared/Tests/StintDataTests/SyncIntegrationTests.swift` (add one test inside `struct SyncIntegrationTests`)

**Interfaces:**
- Consumes: `SyncEngine.client` (internal), `SyncCoding.encoder/decoder`, and `rpc/share_data` (Task 1).
- Produces (used by Task 4):

```swift
public struct ShareLinkRow: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID; public let token: String; public let friendLabel: String; public let createdAt: Date
    public func url(base: String) -> URL?
}
extension SyncEngine {
    public func shareLinks() async throws -> [ShareLinkRow]          // active only, oldest first
    public func createShareLink(label: String) async throws -> ShareLinkRow
    public func revokeShareLink(id: UUID) async throws
}
```

- [ ] **Step 1: Write the failing unit test** `Shared/Tests/StintDataTests/ShareLinkTests.swift`:

```swift
import Testing
import Foundation
@testable import StintData

@Suite struct ShareLinkTests {
    @Test func decodesServerRow() throws {
        let json = #"{"id":"6b0e1c9a-2f43-4c5e-9b1a-0d9f3c2e7a11","token":"\#(String(repeating: "a", count: 43))","friend_label":"Sam","created_at":"2026-11-26T10:00:00.123456+00:00"}"#
        let row = try SyncCoding.decoder.decode(ShareLinkRow.self, from: Data(json.utf8))
        #expect(row.friendLabel == "Sam" && row.token.count == 43)
    }

    @Test func urlAppendsToken() {
        let row = ShareLinkRow(id: UUID(), token: "abc_-DEF", friendLabel: "", createdAt: .now)
        #expect(row.url(base: "https://gilbertvirgo.github.io/productivity/")?.absoluteString
                == "https://gilbertvirgo.github.io/productivity/?t=abc_-DEF")
        #expect(row.url(base: "") == nil)
    }
}
```

- [ ] **Step 2: Run it and confirm it fails.** Run `cd Shared && swift test --disable-sandbox --filter ShareLinkTests`. Expected: compile error, `cannot find 'ShareLinkRow'`.

- [ ] **Step 3: Implement** `Shared/Sources/StintData/Sync/ShareLinks.swift`:

```swift
import Foundation
import Supabase

/// One friend's link to the share page (spec §6.10). `friendLabel` is for the owner only; the page never sees it.
public struct ShareLinkRow: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let token: String
    public let friendLabel: String
    public let createdAt: Date

    public init(id: UUID, token: String, friendLabel: String, createdAt: Date) {
        self.id = id; self.token = token; self.friendLabel = friendLabel; self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey { case id, token, friendLabel = "friend_label", createdAt = "created_at" }

    /// The page address for this link; nil when the app has no share page configured.
    public func url(base: String) -> URL? {
        base.isEmpty ? nil : URL(string: base + "?t=" + token) // tokens are base64url: no escaping needed
    }
}

private struct Revocation: Encodable {
    let revokedAt: Date, updatedAt: Date
    enum CodingKeys: String, CodingKey { case revokedAt = "revoked_at", updatedAt = "updated_at" }
}

private struct NewLink: Encodable {
    let friendLabel: String
    enum CodingKeys: String, CodingKey { case friendLabel = "friend_label" }
}

extension SyncEngine {
    static let shareLinkColumns = "id, token, friend_label, created_at"

    /// Active links, oldest first. Revoked rows stay on the server so a revoked token never comes back to life.
    public func shareLinks() async throws -> [ShareLinkRow] {
        try await client.from("share_link").select(Self.shareLinkColumns)
            .is("revoked_at", value: nil).order("created_at").execute().value
    }

    /// The server mints the token (32 random bytes, base64url).
    public func createShareLink(label: String) async throws -> ShareLinkRow {
        try await client.from("share_link").insert(NewLink(friendLabel: label), returning: .representation)
            .select(Self.shareLinkColumns).single().execute().value
    }

    public func revokeShareLink(id: UUID) async throws {
        let now = Date.now
        try await client.from("share_link").update(Revocation(revokedAt: now, updatedAt: now))
            .eq("id", value: id).execute()
    }
}
```

If supabase-swift 2.55's `.is(_:value:)` has a different signature, use the form it offers that renders `revoked_at=is.null`. Note this in your report.

- [ ] **Step 4: Run the unit test.** Run `cd Shared && swift test --disable-sandbox --filter ShareLinkTests`. Expected: PASS (2).

- [ ] **Step 5: Add an integration test** inside `struct SyncIntegrationTests` in `Shared/Tests/StintDataTests/SyncIntegrationTests.swift`. It reuses the file's private `signedInClient()` and `MemoryStorage`.

```swift
    @Test func shareLinkLifecycleAndPage() async throws {
        let (client, _) = try await signedInClient()
        let engine = SyncEngine(client: client, context: try ctx(), defaults: defaults())
        let link = try await engine.createShareLink(label: "Sam")
        #expect(link.token.count == 43 && link.friendLabel == "Sam")
        #expect(try await engine.shareLinks().map(\.id) == [link.id])

        // The page is anonymous: no session, anon key only.
        let env = ProcessInfo.processInfo.environment
        let anon = SupabaseClient(supabaseURL: URL(string: env["STINT_SUPABASE_URL"]!)!, supabaseKey: env["STINT_SUPABASE_ANON_KEY"]!,
                                  options: .init(auth: .init(storage: MemoryStorage(), emitLocalSessionAsInitialSession: true)))
        func page() async throws -> String {
            String(decoding: try await anon.rpc("share_data", params: ["p_token": link.token]).execute().data, as: UTF8.self)
        }
        #expect(try await page().contains("\"projects\""))
        #expect(!(try await page().contains("Sam")))

        try await engine.revokeShareLink(id: link.id)
        #expect(try await engine.shareLinks().isEmpty)
        #expect(try await page() == "null")
    }
```

- [ ] **Step 6: Run the integration test against the local stack.** The migration from Task 1 must already be applied.

```bash
cd Shared && STINT_SUPABASE_URL=http://127.0.0.1:54321 STINT_SUPABASE_ANON_KEY=$(cd .. && supabase status -o env | sed -n 's/^ANON_KEY="\(.*\)"/\1/p') swift test --disable-sandbox --filter "SyncIntegration|ShareLink"
```

Expected: all pass. Then run the whole suite, `cd Shared && swift test --disable-sandbox`; with no env set, the integration tests are skipped.

- [ ] **Step 7: Commit.**

```bash
git add Shared/Sources/StintData/Sync/ShareLinks.swift Shared/Tests/StintDataTests/ShareLinkTests.swift Shared/Tests/StintDataTests/SyncIntegrationTests.swift
git commit -m "feat(sync): share links (list, create, revoke)"
```

---

### Task 4: Mac Friends section

**Files:**
- Create: `Mac/UI/FriendsView.swift`
- Modify:
  - `Mac/UI/MainWindow.swift`: add `.friends` to `MainSection` and its detail case.
  - `Mac/App/SyncCoordinator.swift`: add share-link pass-throughs and `shareURL`.
  - `project.yml`: add the `STINT_SHARE_URL` setting and the `StintShareURL` Info key.
- Test: `MacTests/FriendsTests.swift`

**Interfaces:**
- Consumes (Task 3): `ShareLinkRow`, `ShareLinkRow.url(base:)`, and `SyncEngine.shareLinks()` / `createShareLink(label:)` / `revokeShareLink(id:)`.
- Produces: `SyncCoordinator.shareLinks()`, `createShareLink(label:)` and `revokeShareLink(_:)`, each `async throws`; `SyncCoordinator.shareURL(_ link: ShareLinkRow) -> URL?`; and `static func shareBase(info:) -> String`.

- [ ] **Step 1: Add the share page base URL to `project.yml`.**
  - Under `settings.base`, next to `STINT_SUPABASE_URL`, add `STINT_SHARE_URL: "http:/$()/127.0.0.1:8787/"`.
  - In the Release `configs` block that blanks the Supabase values, add `STINT_SHARE_URL: "https:/$()/gilbertvirgo.github.io/productivity/"`.
  - In the StintMac `info.properties`, next to `StintSupabaseAnonKey`, add `StintShareURL: $(STINT_SHARE_URL)`.
  - Then run `xcodegen generate`.

- [ ] **Step 2: Write the failing test** `MacTests/FriendsTests.swift`:

```swift
import Foundation
import Testing
import StintData
@testable import Stint

@MainActor @Suite struct FriendsTests {
    @Test func shareBaseReadsInfoAndIgnoresUnexpanded() {
        #expect(SyncCoordinator.shareBase(info: ["StintShareURL": "http://127.0.0.1:8787/"]) == "http://127.0.0.1:8787/")
        #expect(SyncCoordinator.shareBase(info: ["StintShareURL": "$(STINT_SHARE_URL)"]) == "")
        #expect(SyncCoordinator.shareBase(info: nil) == "")
    }
}
```

- [ ] **Step 3: Run it and confirm it fails.** Run `xcodebuild -scheme StintMac -derivedDataPath /private/tmp/claude-501/dd2 PRODUCT_BUNDLE_IDENTIFIER=dev.stint.mac.alt test`. Expected: compile error, `type 'SyncCoordinator' has no member 'shareBase'`.

- [ ] **Step 4: Add to `Mac/App/SyncCoordinator.swift`.** Put this in a new `// MARK: friends` section after `parseTasks`.

```swift
    // MARK: friends

    private var shareBaseURL: String { Self.shareBase(info: Bundle.main.infoDictionary) }

    /// `StintShareURL` from Info.plist; "" when missing or an unexpanded `$(…)`.
    static func shareBase(info: [String: Any]?) -> String {
        guard let s = info?["StintShareURL"] as? String, !s.hasPrefix("$(") else { return "" }
        return s
    }

    func shareURL(_ link: ShareLinkRow) -> URL? { link.url(base: shareBaseURL) }

    func shareLinks() async throws -> [ShareLinkRow] {
        guard let engine, userID != nil else { throw NotSignedIn() }
        return try await engine.shareLinks()
    }

    func createShareLink(label: String) async throws -> ShareLinkRow {
        guard let engine, userID != nil else { throw NotSignedIn() }
        return try await engine.createShareLink(label: label.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func revokeShareLink(_ link: ShareLinkRow) async throws {
        guard let engine, userID != nil else { throw NotSignedIn() }
        try await engine.revokeShareLink(id: link.id)
    }
```

- [ ] **Step 5: Write `Mac/UI/FriendsView.swift`.**

```swift
import SwiftUI
import StintData

/// Spec §6.10: one revocable link per friend. Links live on the server only (they need the account anyway).
struct FriendsView: View {
    @Environment(SyncCoordinator.self) private var sync
    @State private var links: [ShareLinkRow] = []
    @State private var label = ""
    @State private var error: String?
    @State private var busy = false
    @State private var revoking: ShareLinkRow?

    private var signedIn: Bool { if case .signedIn = sync.state { true } else { false } }

    var body: some View {
        Form {
            if !signedIn {
                Text("Sign in under Account to share your goals with friends.").foregroundStyle(.secondary)
            } else {
                Section {
                    Text("Friends see only the projects you mark \u{201C}Show on share page\u{201D}, by the name you give them, with this week's goals and results. Never project names, tasks, apps, sites or points.")
                        .foregroundStyle(.secondary)
                }
                Section("New link") {
                    TextField("Who is it for? Only you see this.", text: $label)
                    Button("Create link") { Task { await create() } }.disabled(busy)
                }
                Section("Links") {
                    if links.isEmpty { Text("No links yet.").foregroundStyle(.secondary) }
                    ForEach(links) { link in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(link.friendLabel.isEmpty ? "Unnamed link" : link.friendLabel)
                                Text("Created \(link.createdAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let url = sync.shareURL(link) {
                                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                                }
                            }
                            Button("Revoke", role: .destructive) { revoking = link }
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(Theme.warn) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Friends")
        .task(id: signedIn) { await load() }
        .confirmationDialog("Revoke this link?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
                            presenting: revoking) { link in
            Button("Revoke", role: .destructive) { Task { await revoke(link) } }
        } message: { _ in
            Text("Anyone with it will see \u{201C}This link isn't active.\u{201D} You can make a new one later.")
        }
    }

    private func load() async {
        guard signedIn else { links = []; return }
        do { links = try await sync.shareLinks(); error = nil } catch { self.error = error.localizedDescription }
    }

    private func create() async {
        busy = true; defer { busy = false }
        do { links.append(try await sync.createShareLink(label: label)); label = ""; error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func revoke(_ link: ShareLinkRow) async {
        do { try await sync.revokeShareLink(link); links.removeAll { $0.id == link.id }; error = nil }
        catch { self.error = error.localizedDescription }
    }
}
```

- [ ] **Step 6: Wire up `Mac/UI/MainWindow.swift`.**
  - Add `friends = "Friends"` to `MainSection`, between `rewards` and `account`.
  - Give it the icon `"person.2"`.
  - Add the detail case `case .friends: FriendsView()`.

- [ ] **Step 7: Run the Mac tests.** Run `xcodebuild -scheme StintMac -derivedDataPath /private/tmp/claude-501/dd2 PRODUCT_BUNDLE_IDENTIFIER=dev.stint.mac.alt test`, then `rm -rf /private/tmp/claude-501/dd2`. Expected: all pass (11 existing + 1 new = 12).

- [ ] **Step 8: Commit.**

```bash
git add project.yml Mac/UI/FriendsView.swift Mac/UI/MainWindow.swift Mac/App/SyncCoordinator.swift MacTests/FriendsTests.swift
git commit -m "feat(mac): Friends section to create, share and revoke links"
```

- [ ] **Step 9: Manual check (controller).**
  1. Insert a share link for the simulator's SIWA test user (d1374769…) with psql. Mark project Northwind `shared = true`, alias "Client A", with a weekly goal.
  2. Start the `share-site` preview and open `http://127.0.0.1:8787/?t=<token>`.
  3. Expected: "<display name>'s week", one card "Client A" with goals and status, and "Northwind" nowhere on the page.
  4. Revoke the link (set `revoked_at`) and reload. Expected: "This link isn't active."
  5. Reset the test data afterwards: `shared = false` and the alias back.
