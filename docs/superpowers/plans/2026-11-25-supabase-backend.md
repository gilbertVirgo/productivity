# Stint Supabase Backend Implementation Plan (plan 2 of 8)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Postgres side of Stint on local Supabase (Docker). It has three parts:
- every spec §5 table, with RLS;
- a `session_totals` view that matches Core's accounting to the second;
- an hourly `close_periods` job that writes `goal_result` rows and goal points.

**Architecture:**
- **Layout.** Plain SQL migrations live in `supabase/migrations/`. The three areas are separate migration files: schema+RLS, totals, period close.
- **Session totals.** `compute_session_totals(start, end, events jsonb)` is a PL/pgSQL port of `Core.sessionTotals`, line for line. The view feeds it each session's events.
- **Period close.** `close_periods(now)` is `security definer`. It is idempotent through a unique key on `goal_result`, and pg_cron calls it hourly.
- **Tests.** Tests are pgTAP files in `supabase/tests/`, run with `supabase test db`.

**Tech Stack:** Supabase CLI 3.4 (local stack in Docker), Postgres 15+/17, PL/pgSQL, pgTAP, pg_cron, pgcrypto (`extensions` schema).

**Spec:** `docs/superpowers/specs/2026-11-24-freelance-focus-app-design.md`. The relevant sections are §5 (data model), §6.1 (time boundaries), §6.2 (goals), §6.3 (overlap priority), §6.7 (points), §6.10 (share link token), §6.11 (session_command), and §8 ("Mirror Core").

## Global Constraints

- **Common columns.** Every table has `id uuid primary key default gen_random_uuid()`, plus:
  - `user_id uuid not null default auth.uid() references auth.users(id) on delete cascade`
  - `created_at timestamptz not null default now()`
  - `updated_at timestamptz not null default now()`
- **`updated_at`** is set by the client: sync is last-write-wins on the client's `updated_at` (§6.11). **No trigger overwrites it.**
- **RLS.** RLS is on for every table, and the owner rule is `user_id = (select auth.uid())`. The anon role gets nothing.
  - `session_event` and `point_event` are append-only for clients: select and insert only.
  - `goal_result` is select-only for clients. Only `close_periods` writes it.
- **Cross-row ownership.** A child row's `project_id`/`session_id` must belong to the same user. Enforce this with composite foreign keys `(project_id, user_id) references project(id, user_id)`, because FK checks bypass RLS.
- **Enum strings must match Core's raw values exactly.**
  - Event types: `offtask_start offtask_end break_start break_end idle_start idle_end sleep wake`.
  - Point kinds: `focus offtask redeem session_complete daily_goal weekly_goal break_over`.
  - Others: `end_kind completed|early`, `kind app|domain`, `source manual|voice`, `tasks_goal_period day|week`, goal `period day|week`, `goal_kind hours|tasks`.
- **Positive targets.** `treat.cost > 0`. Goal targets (`weekly_hours_goal`, `daily_hours_goal`, `tasks_goal`) are null or > 0, where null means no goal. `goal_result.target > 0`. This carries over a deferred item from plan 1.
- **Session accounting** (§8 Mirror Core):
  - Every timestamp is floored with `date_trunc('second', …)`.
  - Priority is break > sleep > idle > off-task > focused.
  - At the same instant, start-type events sort before end-type events.
  - An open state runs to the end.
  - Events outside `[start, end]` are ignored.
  - `end <= start` gives all zeros.
- **Days and weeks** are computed in `profile.timezone`, with ISO weeks running Monday 00:00 to the next Monday 00:00. A session counts toward the day or week its `started_at` falls in.
- **Goal points** mirror `Core.PointRules`: daily goal met is `+20` (`daily_goal`), weekly goal met is `+100` (`weekly_goal`). They are written in the same transaction as the `goal_result`, with `ref_id = goal_result.id` and `note = project.name`.
- **Share token:** 32 random bytes, encoded as base64url without padding (43 characters).
- **Running Docker/Supabase commands.** If `supabase …` or `docker …` fails with a sandbox, socket or `operation not permitted` error, re-run that Bash command with the sandbox disabled.
- Work directly on `main`. Commit trailer: `Co-Authored-By: <model you run as> <noreply@anthropic.com>`.

## Decisions taken in this plan (rulings against the spec)

- **Daily tasks goals use the same days as daily hours goals.** The spec defines `daily_goal_days` only for hours. Without this ruling, a daily tasks goal would be "missed" every weekend.
- **`close_periods` looks back at most 14 days.** Periods older than that are never closed. This only matters if cron has been down for two weeks. The limit is marked in the code as a `ponytail:` comment.
- **Unfinished sessions are excluded.** Only sessions with `ended_at is not null` count toward goals. A session still running at the hour mark is picked up by the next run only if its period has not closed yet. Spec 6.2 already accepts that late data does not reopen a closed period.
- **`planned_min > 0`, not `in (25,50,90)`.** The Mac DEBUG build allows 1-minute sessions, and they will sync.
- **`week_start` is fixed at 1** (`check (week_start = 1)`). The spec defines weeks as Monday-based only.
- **Clients can insert `point_event` rows.** Session points are computed on the Mac (§6.7), and a personal tool doesn't need a server-side check.
- **New users get a profile row automatically,** created by a trigger on `auth.users`.

## File map

```
supabase/
  config.toml                         (supabase init; project_id = "stint")
  migrations/
    20261125000001_schema.sql         tables, constraints, indexes, RLS, profile trigger
    20261125000002_session_totals.sql compute_session_totals() + session_totals view
    20261125000003_close_periods.sql  record_goal(), close_periods(), pg_cron schedule
  tests/
    00_schema_test.sql                RLS, ownership, checks, append-only, token
    01_session_totals_test.sql        ports Core SessionAccountingTests
    02_close_periods_test.sql         daily/weekly hours + tasks, tz, idempotence, late sync, archived
README.md                             (modify) "Backend (local)" section
```

---

### Task 1: Supabase project, schema, RLS

**Files:**
- Create: `supabase/` (via `supabase init`), `supabase/migrations/20261125000001_schema.sql`, `supabase/tests/00_schema_test.sql`
- Modify: `README.md`

**Interfaces:**
- Produces:
  - Tables `public.profile`, `project`, `project_allow`, `task`, `session`, `session_allow`, `session_event`, `point_event`, `treat`, `goal_result`, `share_link`, `device`, `session_command`.
  - The composite unique keys `project(id, user_id)` and `session(id, user_id)`.
  - Unique `goal_result(project_id, period, period_start, goal_kind)`.
  - `public.is_valid_timezone(text) returns boolean`.

- [ ] **Step 1: Initialise.** From the repo root, run `supabase init` and answer no to the VS Code/IntelliJ prompts. Set `project_id = "stint"` in `supabase/config.toml`. Start the stack with `supabase start`. The first run pulls several GB of images and can take minutes; run it in the background and wait. Expect it to print the local API URL and keys. Those keys are local-only, not secrets, and must not be committed anywhere besides what `supabase init` generates.

- [ ] **Step 2: Failing test** `supabase/tests/00_schema_test.sql`:

```sql
begin;
select plan(13);

-- two users; the auth.users trigger creates their profiles
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'a@test.local'),
  ('00000000-0000-0000-0000-00000000000b', 'b@test.local');

select is((select count(*)::int from public.profile), 2, 'signup creates a profile per user');

-- act as A
set local role authenticated;
set local request.jwt.claims to '{"sub":"00000000-0000-0000-0000-00000000000a","role":"authenticated"}';

insert into public.project (id, name) values ('10000000-0000-0000-0000-000000000001', 'Northwind');
select is((select count(*)::int from public.project), 1, 'owner sees own project');

select throws_ok(
  $$ insert into public.treat (name, cost) values ('Free', 0) $$,
  '23514', null, 'treat cost must be > 0');

select throws_ok(
  $$ insert into public.project (name, weekly_hours_goal) values ('Zero', 0) $$,
  '23514', null, 'goal target must be > 0');

select throws_ok(
  $$ insert into public.project (name, daily_goal_days) values ('Bad days', '{0,8}') $$,
  '23514', null, 'daily_goal_days must be ISO weekdays');

insert into public.point_event (delta, kind, note) values (50, 'focus', 'Northwind');
update public.point_event set delta = 999;
delete from public.point_event;
select is((select sum(delta)::int from public.point_event), 50, 'point_event is append-only for clients');

select throws_ok(
  $$ insert into public.goal_result (project_id, period, period_start, goal_kind, target, actual, met)
     values ('10000000-0000-0000-0000-000000000001', 'day', '2026-11-24', 'hours', 1, 1, true) $$,
  '42501', null, 'clients cannot write goal_result');

insert into public.share_link (friend_label) values ('Sam');
select matches((select token from public.share_link), '^[A-Za-z0-9_-]{43}$', 'share token is 32 bytes base64url');

-- act as B
reset role;
set local role authenticated;
set local request.jwt.claims to '{"sub":"00000000-0000-0000-0000-00000000000b","role":"authenticated"}';

select is((select count(*)::int from public.project), 0, 'other user sees no projects');
select is((select count(*)::int from public.point_event), 0, 'other user sees no points');

select throws_ok(
  $$ insert into public.task (project_id, title) values ('10000000-0000-0000-0000-000000000001', 'sneaky') $$,
  '23503', null, 'cannot attach a task to another user''s project');

select throws_ok(
  $$ update public.profile set timezone = 'Mars/Olympus' $$,
  '23514', null, 'timezone must be a real IANA name');

-- anon
reset role;
set local role anon;
set local request.jwt.claims to '{"role":"anon"}';
select is((select count(*)::int from public.project), 0, 'anon sees nothing');

select * from finish();
rollback;
```

- [ ] **Step 3:** `supabase test db`. Expect FAIL (relations do not exist).

- [ ] **Step 4: Implement** `supabase/migrations/20261125000001_schema.sql`:

```sql
-- Stint schema (spec §5). updated_at is client-set for last-write-wins sync (§6.11): no trigger touches it.

create or replace function public.is_valid_timezone(tz text) returns boolean
language sql immutable as $$ select exists (select 1 from pg_timezone_names where name = tz) $$;

create table public.profile (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique default auth.uid() references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  timezone text not null default 'UTC' check (public.is_valid_timezone(timezone)),
  week_start smallint not null default 1 check (week_start = 1),
  break_allowance_min int not null default 60 check (break_allowance_min >= 0),
  display_name text not null default ''
);

create table public.project (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  name text not null,
  share_alias text not null default '',
  color text not null default '#0F7B6C',
  weekly_hours_goal numeric check (weekly_hours_goal > 0),
  daily_hours_goal numeric check (daily_hours_goal > 0),
  daily_goal_days smallint[] not null default '{1,2,3,4,5}' check (daily_goal_days <@ '{1,2,3,4,5,6,7}'::smallint[]),
  tasks_goal int check (tasks_goal > 0),
  tasks_goal_period text not null default 'week' check (tasks_goal_period in ('day', 'week')),
  shared boolean not null default false,
  archived_at timestamptz,
  unique (id, user_id)
);

create table public.project_allow (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  project_id uuid not null,
  kind text not null check (kind in ('app', 'domain')),
  value text not null check (value <> ''),
  label text not null default '',
  foreign key (project_id, user_id) references public.project (id, user_id) on delete cascade
);

create table public.task (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  project_id uuid not null,
  title text not null,
  estimate_min int check (estimate_min > 0),
  estimate_guessed boolean not null default false,
  done_at timestamptz,
  source text not null default 'manual' check (source in ('manual', 'voice')),
  sort int not null default 0,
  foreign key (project_id, user_id) references public.project (id, user_id) on delete cascade
);

create table public.session (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  project_id uuid not null,
  first_task_id uuid references public.task (id) on delete set null,
  planned_min int not null check (planned_min > 0),
  started_at timestamptz not null,
  ended_at timestamptz,
  end_kind text check (end_kind in ('completed', 'early')),
  early_reason text,
  device text not null default 'mac',
  unique (id, user_id),
  check (ended_at is null or ended_at >= started_at),
  check ((ended_at is null) = (end_kind is null)),
  foreign key (project_id, user_id) references public.project (id, user_id) on delete cascade
);

create table public.session_allow (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  session_id uuid not null,
  kind text not null check (kind in ('app', 'domain')),
  value text not null check (value <> ''),
  label text not null default '',
  added_mid_session boolean not null default false,
  reason text,
  foreign key (session_id, user_id) references public.session (id, user_id) on delete cascade
);

create table public.session_event (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  session_id uuid not null,
  at timestamptz not null,
  type text not null check (type in ('offtask_start', 'offtask_end', 'break_start', 'break_end',
                                     'idle_start', 'idle_end', 'sleep', 'wake')),
  detail jsonb not null default '{}',
  foreign key (session_id, user_id) references public.session (id, user_id) on delete cascade
);

create table public.point_event (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  at timestamptz not null default now(),
  delta int not null,
  kind text not null check (kind in ('focus', 'offtask', 'redeem', 'session_complete',
                                     'daily_goal', 'weekly_goal', 'break_over')),
  ref_id uuid,
  note text not null default ''
);

create table public.treat (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  name text not null,
  cost int not null check (cost > 0),
  archived_at timestamptz
);

create table public.goal_result (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  project_id uuid not null,
  period text not null check (period in ('day', 'week')),
  period_start date not null,
  goal_kind text not null check (goal_kind in ('hours', 'tasks')),
  target numeric not null check (target > 0),
  actual numeric not null,
  met boolean not null,
  unique (project_id, period, period_start, goal_kind),
  foreign key (project_id, user_id) references public.project (id, user_id) on delete cascade
);

create table public.share_link (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  token text not null unique
    default rtrim(translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/', '-_'), '='),
  friend_label text not null default '',
  revoked_at timestamptz
);

create table public.device (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  platform text not null check (platform in ('mac', 'ios')),
  apns_token text,
  push_to_start_token text
);

create table public.session_command (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  kind text not null check (kind in ('start', 'break', 'resume', 'end_early_request')),
  payload jsonb not null default '{}'
);

create index on public.project (user_id);
create index on public.task (project_id);
create index on public.session (user_id, started_at);
create index on public.session (project_id, started_at);
create index on public.session_event (session_id);
create index on public.point_event (user_id, at);
create index on public.goal_result (user_id, period_start);

-- RLS: owner-only. Append-only / server-written tables get narrower policies below.
do $$
declare t text;
begin
  foreach t in array array['profile', 'project', 'project_allow', 'task', 'session', 'session_allow',
                           'treat', 'share_link', 'device', 'session_command'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy owner_all on public.%I for all to authenticated
                    using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()))', t);
  end loop;
  foreach t in array array['session_event', 'point_event'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy owner_select on public.%I for select to authenticated
                    using (user_id = (select auth.uid()))', t);
    execute format('create policy owner_insert on public.%I for insert to authenticated
                    with check (user_id = (select auth.uid()))', t);
  end loop;
end $$;

alter table public.goal_result enable row level security;
create policy owner_select on public.goal_result for select to authenticated using (user_id = (select auth.uid()));

-- New auth user → profile row.
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into public.profile (user_id) values (new.id);
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();
```

- [ ] **Step 5:** run `supabase db reset` (it applies the migrations), then `supabase test db`. Expect `00_schema_test.sql .. ok`, all 13 passing. If one fails because of a local-stack difference, fix the SQL rather than weakening the assertion, and say what you changed in your report. Two examples of such a difference: `gen_random_bytes` not living in `extensions`, or a different SQLSTATE.

- [ ] **Step 6: README.** Add a "Backend (local)" section:
  - Prerequisites are Docker Desktop running and `brew install supabase/tap/supabase`.
  - `supabase start` runs the local stack; its first run downloads images.
  - `supabase db reset` re-applies the migrations, and `supabase test db` runs the SQL tests.
  - `supabase stop` stops the stack.
  - The hosted project, and linking to it, come in plan 4.

- [ ] **Step 7: Commit** `feat(db): add Supabase schema with RLS`. Commit `supabase/config.toml`, `supabase/.gitignore`, the migration, the test and the README. Do not commit `supabase/.temp/` or `supabase/.branches/`; the `.gitignore` that `supabase init` creates already covers them.

---

### Task 2: `session_totals`, mirroring Core

**Files:**
- Create: `supabase/migrations/20261125000002_session_totals.sql`, `supabase/tests/01_session_totals_test.sql`

**Interfaces:**
- Consumes: `public.session`, `public.session_event` (Task 1).
- Produces:
  - `public.compute_session_totals(p_start timestamptz, p_end timestamptz, p_events jsonb) returns table (focused_sec int, offtask_sec int, break_sec int, idle_sec int, sleep_sec int)`. `p_events` is a JSON array of `{"type": text, "at": timestamptz}`.
  - The view `public.session_totals (session_id, user_id, focused_sec, offtask_sec, break_sec, idle_sec, sleep_sec)`. It uses `security_invoker`, so RLS applies, and an open session runs to `now()`.

- [ ] **Step 1: Failing test** `supabase/tests/01_session_totals_test.sql`. This ports `Shared/Tests/CoreTests/SessionAccountingTests.swift` case by case. Each row is `(focused,offtask,break,idle,sleep)`.

```sql
begin;
select plan(13);

create function pg_temp.t(m numeric) returns timestamptz language sql immutable as
  $$ select '2026-11-24 16:00:00+00'::timestamptz + make_interval(secs => m * 60) $$;
create function pg_temp.ev(type text, m numeric) returns jsonb language sql immutable as
  $$ select jsonb_build_object('type', type, 'at', pg_temp.t(m)) $$;
create function pg_temp.tot(s timestamptz, e timestamptz, evs jsonb) returns text language sql as
  $$ select (focused_sec, offtask_sec, break_sec, idle_sec, sleep_sec)::text
       from public.compute_session_totals(s, e, evs) $$;

select is(pg_temp.tot(pg_temp.t(0), pg_temp.t(50), '[]'), '(3000,0,0,0,0)', 'no events is all focused');

select is(pg_temp.tot(pg_temp.t(0), pg_temp.t(50), jsonb_build_array(
  pg_temp.ev('offtask_start', 10), pg_temp.ev('offtask_end', 15))), '(2700,300,0,0,0)', 'off-task stretch');

select is(pg_temp.tot(pg_temp.t(0), pg_temp.t(60), jsonb_build_array(
  pg_temp.ev('break_start', 20), pg_temp.ev('break_end', 30))), '(3000,0,600,0,0)', 'break is its own bucket');

select is(pg_temp.tot(pg_temp.t(0), pg_temp.t(50), jsonb_build_array(
  pg_temp.ev('offtask_start', 10), pg_temp.ev('idle_start', 12),
  pg_temp.ev('idle_end', 15), pg_temp.ev('offtask_end', 15))), '(2700,120,0,180,0)', 'idle beats off-task');

select is(pg_temp.tot(pg_temp.t(0), pg_temp.t(60), jsonb_build_array(
  pg_temp.ev('break_start', 10), pg_temp.ev('sleep', 12),
  pg_temp.ev('wake', 20), pg_temp.ev('break_end', 22))), '(2880,0,720,0,0)', 'break beats sleep');

select is(pg_temp.tot(pg_temp.t(0), pg_temp.t(60), jsonb_build_array(
  pg_temp.ev('sleep', 10), pg_temp.ev('wake', 20))), '(3000,0,0,0,600)', 'sleep is its own bucket');

select is(pg_temp.tot(pg_temp.t(0), pg_temp.t(50), jsonb_build_array(
  pg_temp.ev('offtask_start', 45))), '(2700,300,0,0,0)', 'open state runs to end');

select is(pg_temp.tot(pg_temp.t(0), pg_temp.t(50), jsonb_build_array(
  pg_temp.ev('offtask_end', 15), pg_temp.ev('offtask_start', 10), pg_temp.ev('break_start', 70))),
  '(2700,300,0,0,0)', 'events outside window ignored, order does not matter');

select is(pg_temp.tot(pg_temp.t(0), pg_temp.t(0) + interval '3000 seconds', jsonb_build_array(
  jsonb_build_object('type', 'offtask_start', 'at', pg_temp.t(0) + interval '100.3 seconds'),
  jsonb_build_object('type', 'offtask_end',   'at', pg_temp.t(0) + interval '200.6 seconds'))),
  '(2900,100,0,0,0)', 'fractional seconds floored; buckets sum to session length');

select is(pg_temp.tot(pg_temp.t(10), pg_temp.t(5), '[]'), '(0,0,0,0,0)', 'end before start is empty');

select is(pg_temp.tot(pg_temp.t(0), pg_temp.t(50), jsonb_build_array(
  pg_temp.ev('offtask_end', 15), pg_temp.ev('offtask_start', 15))), '(3000,0,0,0,0)',
  'same timestamp: start sorts before end');

-- the view: closed session reads its own events; RLS via security_invoker
insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000a', 'a@test.local');
insert into public.project (id, user_id, name)
  values ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', 'Northwind');
insert into public.session (id, user_id, project_id, planned_min, started_at, ended_at, end_kind)
  values ('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a',
          '10000000-0000-0000-0000-000000000001', 50, pg_temp.t(0), pg_temp.t(50), 'completed');
insert into public.session_event (user_id, session_id, at, type) values
  ('00000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000001', pg_temp.t(10), 'offtask_start'),
  ('00000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000001', pg_temp.t(15), 'offtask_end');

select is((select (focused_sec, offtask_sec)::text from public.session_totals
           where session_id = '20000000-0000-0000-0000-000000000001'), '(2700,300)', 'view uses session events');

set local role authenticated;
set local request.jwt.claims to '{"sub":"00000000-0000-0000-0000-00000000000b","role":"authenticated"}';
select is((select count(*)::int from public.session_totals), 0, 'view respects RLS');

select * from finish();
rollback;
```

Note: the Swift fractional case asserts only `activeSec == 3000`. Here the exact split is pinned. The off-task start floors 100.3 to 100 and the end floors 200.6 to 200, so off-task is 100 and focused is 2900.

- [ ] **Step 2:** `supabase test db`. Expect FAIL for 01 (function missing). 00 still passes.

- [ ] **Step 3: Implement** `supabase/migrations/20261125000002_session_totals.sql`:

```sql
-- Port of Core.sessionTotals (Shared/Sources/Core/SessionAccounting.swift). Keep the two in lockstep (spec §8).
-- Whole-second rule; priority break > sleep > idle > off-task > focused; start-type events sort before
-- end-type at the same instant; open states run to p_end; events outside [start, end] ignored.
create function public.compute_session_totals(p_start timestamptz, p_end timestamptz, p_events jsonb)
returns table (focused_sec int, offtask_sec int, break_sec int, idle_sec int, sleep_sec int)
language plpgsql immutable as $$
declare
  s timestamptz := date_trunc('second', p_start);
  e timestamptz := date_trunc('second', p_end);
  cur timestamptz := date_trunc('second', p_start);
  d int;
  is_off boolean := false; is_break boolean := false; is_idle boolean := false; is_asleep boolean := false;
  ev record;
begin
  focused_sec := 0; offtask_sec := 0; break_sec := 0; idle_sec := 0; sleep_sec := 0;
  if e <= s then
    return next;
    return;
  end if;
  -- the trailing row (type null at e) flushes the last open stretch
  for ev in
    select x.type, x.at from (
      select j.type, date_trunc('second', j.at) as at,
             case when j.type in ('offtask_start', 'break_start', 'idle_start', 'sleep') then 0 else 1 end as ord
        from jsonb_to_recordset(coalesce(p_events, '[]'::jsonb)) as j(type text, at timestamptz)
      union all
      select null, e, 2
    ) x
    where x.at between s and e
    order by x.at, x.ord
  loop
    d := extract(epoch from (ev.at - cur))::int;
    if is_break then break_sec := break_sec + d;
    elsif is_asleep then sleep_sec := sleep_sec + d;
    elsif is_idle then idle_sec := idle_sec + d;
    elsif is_off then offtask_sec := offtask_sec + d;
    else focused_sec := focused_sec + d;
    end if;
    cur := ev.at;
    case ev.type
      when 'offtask_start' then is_off := true;
      when 'offtask_end' then is_off := false;
      when 'break_start' then is_break := true;
      when 'break_end' then is_break := false;
      when 'idle_start' then is_idle := true;
      when 'idle_end' then is_idle := false;
      when 'sleep' then is_asleep := true;
      when 'wake' then is_asleep := false;
      else null;
    end case;
  end loop;
  return next;
end $$;

create view public.session_totals with (security_invoker = true) as
select s.id as session_id, s.user_id, t.focused_sec, t.offtask_sec, t.break_sec, t.idle_sec, t.sleep_sec
from public.session s
cross join lateral public.compute_session_totals(
  s.started_at,
  coalesce(s.ended_at, now()),
  coalesce((select jsonb_agg(jsonb_build_object('type', ev.type, 'at', ev.at))
              from public.session_event ev where ev.session_id = s.id), '[]'::jsonb)
) t;
```

- [ ] **Step 4:** `supabase db reset && supabase test db`. Expect both files to pass, with 13 + 13 assertions.
- [ ] **Step 5: Commit** `feat(db): add session_totals mirroring Core accounting`.

---

### Task 3: Period close (`close_periods`) + hourly pg_cron job

**Files:**
- Create: `supabase/migrations/20261125000003_close_periods.sql`, `supabase/tests/02_close_periods_test.sql`

**Interfaces:**
- Consumes: `profile.timezone`, the `project` goal columns, `session` (with `ended_at`), `session_totals.focused_sec`, `task.done_at`, `goal_result`, `point_event`.
- Produces:
  - `public.close_periods(p_now timestamptz default now()) returns int`. It returns the number of `goal_result` rows written by that call.
  - `public.record_goal(p_project public.project, p_period text, p_start date, p_kind text, p_target numeric, p_actual numeric, p_met boolean, p_now timestamptz) returns int`. It returns 1 if it wrote a row and 0 if the row already existed.
  - Both are `security definer` with execute revoked from `public`, `anon` and `authenticated`.
  - A pg_cron job named `close-periods` runs at minute 5 of every hour.

Rules:
- **Per profile:** `today = (p_now at time zone tz)::date`. Each period's bounds are local midnights turned into instants, e.g. `d::timestamp at time zone tz`. This keeps DST correct.
- **Projects:** non-archived ones only. Days run from `greatest(local date of project.created_at, today − 14)` to `today − 1`. Weeks are the ISO-Monday weeks fully before the current week, back to the Monday on or before the same lower bound.
- **Days.** A day gets goals only if `isodow ∈ daily_goal_days`. On such a day:
  - `daily_hours_goal` is set: the hours row, where actual is the focused hours of ended sessions that started that day.
  - `tasks_goal_period = 'day'`: the tasks row, where actual is the number of tasks with `done_at` that day.
- **Weeks:**
  - `weekly_hours_goal` is set: the hours row.
  - `tasks_goal_period = 'week'`: the tasks row.
- **Stored values:** hours `actual` is rounded to 2 decimals for storage. `met` compares the unrounded seconds against `target × 3600`, while for tasks `met = count >= target`.
- **Points:** a met day row inserts `point_event (+20, 'daily_goal')`. A met week row inserts `+100, 'weekly_goal'`. Both use `at = p_now`, `ref_id = goal_result.id` and `note = project.name`, in the same transaction.
- **Idempotent:** `insert … on conflict (project_id, period, period_start, goal_kind) do nothing`. Points are only awarded when a row was actually inserted.

- [ ] **Step 1: Failing test** `supabase/tests/02_close_periods_test.sql`. The calendar is November 2026: Mon 16 to Sun 22, Mon 23, Tue 24. Close runs at Tue 24 12:00 UTC.

```sql
begin;
select plan(14);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'a@test.local'),
  ('00000000-0000-0000-0000-00000000000b', 'b@test.local');
update public.profile set timezone = 'Europe/London' where user_id = '00000000-0000-0000-0000-00000000000a';
update public.profile set timezone = 'America/New_York' where user_id = '00000000-0000-0000-0000-00000000000b';

-- A: daily 1 h Mon–Fri, weekly 4 h, 2 tasks/week
insert into public.project (id, user_id, name, created_at, daily_hours_goal, weekly_hours_goal, tasks_goal, tasks_goal_period)
values ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', 'Northwind',
        '2026-11-01', 1, 4, 2, 'week');
-- A: archived project with a goal → never closed
insert into public.project (id, user_id, name, created_at, daily_hours_goal, archived_at)
values ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000000a', 'Old',
        '2026-11-01', 1, '2026-11-02');
-- B: daily 1 h, all days
insert into public.project (id, user_id, name, created_at, daily_hours_goal, daily_goal_days)
values ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-00000000000b', 'Acme',
        '2026-11-01', 1, '{1,2,3,4,5,6,7}');

create function pg_temp.sess(uid text, pid text, s timestamptz, mins int, ended boolean default true)
returns void language sql as $$
  insert into public.session (user_id, project_id, planned_min, started_at, ended_at, end_kind)
  values (uid::uuid, pid::uuid, mins, s,
          case when ended then s + make_interval(mins => mins) end,
          case when ended then 'completed' end) $$;

select pg_temp.sess('00000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', '2026-11-16 09:00+00', 60);  -- Mon: met
select pg_temp.sess('00000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', '2026-11-17 09:00+00', 30);  -- Tue: short
select pg_temp.sess('00000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', '2026-11-19 09:00+00', 90, false); -- Thu: never ended
insert into public.task (user_id, project_id, title, done_at) values
  ('00000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', 'one', '2026-11-18 10:00+00'),
  ('00000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', 'two', '2026-11-18 11:00+00');
-- B: 03:00 UTC Tue 17 = 22:00 Mon 16 in New York → counts for Mon 16
select pg_temp.sess('00000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-000000000003', '2026-11-17 03:00+00', 60);

select is(public.close_periods('2026-11-24 12:00+00'), 28,
  'A: 10 weekdays (Tue 10 – Mon 23) + 2 weeks × (hours, tasks); B: 14 days (Tue 10 – Mon 23)');

create function pg_temp.res(pid text, per text, d date, k text) returns text language sql as $$
  select (actual, met)::text from public.goal_result
  where project_id = pid::uuid and period = per and period_start = d and goal_kind = k $$;

select is(pg_temp.res('10000000-0000-0000-0000-000000000001', 'day', '2026-11-16', 'hours'), '(1.00,t)', 'Mon met');
select is(pg_temp.res('10000000-0000-0000-0000-000000000001', 'day', '2026-11-17', 'hours'), '(0.50,f)', 'Tue short');
select is(pg_temp.res('10000000-0000-0000-0000-000000000001', 'day', '2026-11-19', 'hours'), '(0.00,f)', 'unfinished session excluded');
select is(pg_temp.res('10000000-0000-0000-0000-000000000001', 'day', '2026-11-21', 'hours'), null, 'Saturday has no daily goal');
select is(pg_temp.res('10000000-0000-0000-0000-000000000001', 'week', '2026-11-16', 'hours'), '(1.50,f)', 'week hours missed');
select is(pg_temp.res('10000000-0000-0000-0000-000000000001', 'week', '2026-11-16', 'tasks'), '(2,t)', 'week tasks met');
select is(pg_temp.res('10000000-0000-0000-0000-000000000001', 'week', '2026-11-23', 'hours'), null, 'current week stays open');
select is((select count(*)::int from public.goal_result where project_id = '10000000-0000-0000-0000-000000000002'), 0,
  'archived project not closed');
select is(pg_temp.res('10000000-0000-0000-0000-000000000003', 'day', '2026-11-16', 'hours'), '(1.00,t)',
  'B: day boundary uses profile timezone');

select is((select (sum(delta) filter (where kind = 'daily_goal'), sum(delta) filter (where kind = 'weekly_goal'))::text
           from public.point_event where user_id = '00000000-0000-0000-0000-00000000000a'),
  '(20,100)', 'A: +20 for Mon, +100 for weekly tasks');
select ok((select bool_and(p.ref_id = g.id and p.note = 'Northwind') from public.point_event p
           join public.goal_result g on g.id = p.ref_id
           where p.user_id = '00000000-0000-0000-0000-00000000000a'), 'points reference their goal_result');

-- late sync does not reopen; second run writes nothing
select pg_temp.sess('00000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', '2026-11-17 14:00+00', 60);
select is(public.close_periods('2026-11-24 13:00+00'), 0, 'idempotent: nothing new to close');
select is(pg_temp.res('10000000-0000-0000-0000-000000000001', 'day', '2026-11-17', 'hours'), '(0.50,f)',
  'closed period is not reopened by late data');

select * from finish();
rollback;
```

The expected count of 28 works out as follows:
- **A's days:** Tue 10 to Fri 13 (4 days), Mon 16 to Fri 20 (5) and Mon 23 (1) make 10.
- **A's weeks:** the weeks starting 9 and 16 Nov, each with an hours row and a tasks row, make 4. The week of the 9th is included because the lower bound, 10 Nov, falls inside it.
- **B's days:** Tue 10 to Mon 23 make 14.
- Total: 10 + 4 + 14 = 28.

- [ ] **Step 2:** `supabase test db`. Expect FAIL for 02 (function missing).

- [ ] **Step 3: Implement** `supabase/migrations/20261125000003_close_periods.sql`:

```sql
-- Hourly period close (spec §6.2). Writes goal_result + goal points in one transaction; never reopens.
-- Point values mirror Core.PointRules.dailyGoalMet / weeklyGoalMet.

create function public.record_goal(p_project public.project, p_period text, p_start date, p_kind text,
                                   p_target numeric, p_actual numeric, p_met boolean, p_now timestamptz)
returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare gid uuid;
begin
  insert into goal_result (user_id, project_id, period, period_start, goal_kind, target, actual, met)
  values (p_project.user_id, p_project.id, p_period, p_start, p_kind, p_target, p_actual, p_met)
  on conflict (project_id, period, period_start, goal_kind) do nothing
  returning id into gid;
  if gid is null then return 0; end if;
  if p_met then
    insert into point_event (user_id, at, delta, kind, ref_id, note)
    values (p_project.user_id, p_now,
            case p_period when 'day' then 20 else 100 end,
            case p_period when 'day' then 'daily_goal' else 'weekly_goal' end,
            gid, p_project.name);
  end if;
  return 1;
end $$;

create function public.close_periods(p_now timestamptz default now())
returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  lookback constant int := 14;  -- ponytail: periods older than 14 days are never closed; widen if cron can be down longer
  pr record;
  p public.project;
  tz text;
  today date;
  lower date;
  d date;
  t0 timestamptz;
  t1 timestamptz;
  secs numeric;
  cnt int;
  n int := 0;
begin
  for pr in select user_id, timezone from profile loop
    tz := pr.timezone;
    today := (p_now at time zone tz)::date;
    for p in select * from project where user_id = pr.user_id and archived_at is null loop
      lower := greatest((p.created_at at time zone tz)::date, today - lookback);

      -- days
      for d in select g::date from generate_series(lower, today - 1, interval '1 day') g loop
        continue when not (extract(isodow from d)::smallint = any (p.daily_goal_days));
        t0 := d::timestamp at time zone tz;
        t1 := (d + 1)::timestamp at time zone tz;
        if p.daily_hours_goal is not null then
          select coalesce(sum(st.focused_sec), 0) into secs
            from session s join session_totals st on st.session_id = s.id
           where s.project_id = p.id and s.ended_at is not null and s.started_at >= t0 and s.started_at < t1;
          n := n + record_goal(p, 'day', d, 'hours', p.daily_hours_goal, round(secs / 3600.0, 2),
                               secs >= p.daily_hours_goal * 3600, p_now);
        end if;
        if p.tasks_goal is not null and p.tasks_goal_period = 'day' then
          select count(*) into cnt from task where project_id = p.id and done_at >= t0 and done_at < t1;
          n := n + record_goal(p, 'day', d, 'tasks', p.tasks_goal, cnt, cnt >= p.tasks_goal, p_now);
        end if;
      end loop;

      -- weeks (ISO, Monday start), only those fully before the current week
      for d in select g::date
                 from generate_series(date_trunc('week', lower)::date, date_trunc('week', today)::date - 7,
                                      interval '7 days') g loop
        t0 := d::timestamp at time zone tz;
        t1 := (d + 7)::timestamp at time zone tz;
        if p.weekly_hours_goal is not null then
          select coalesce(sum(st.focused_sec), 0) into secs
            from session s join session_totals st on st.session_id = s.id
           where s.project_id = p.id and s.ended_at is not null and s.started_at >= t0 and s.started_at < t1;
          n := n + record_goal(p, 'week', d, 'hours', p.weekly_hours_goal, round(secs / 3600.0, 2),
                               secs >= p.weekly_hours_goal * 3600, p_now);
        end if;
        if p.tasks_goal is not null and p.tasks_goal_period = 'week' then
          select count(*) into cnt from task where project_id = p.id and done_at >= t0 and done_at < t1;
          n := n + record_goal(p, 'week', d, 'tasks', p.tasks_goal, cnt, cnt >= p.tasks_goal, p_now);
        end if;
      end loop;
    end loop;
  end loop;
  return n;
end $$;

revoke execute on function public.record_goal(public.project, text, date, text, numeric, numeric, boolean, timestamptz)
  from public, anon, authenticated;
revoke execute on function public.close_periods(timestamptz) from public, anon, authenticated;

create extension if not exists pg_cron with schema pg_catalog;
select cron.schedule('close-periods', '5 * * * *', $$ select public.close_periods() $$);
```

- [ ] **Step 4:** `supabase db reset && supabase test db`. Expect all three files to pass (13 + 13 + 14). Also check that the job exists: `psql "$(supabase status -o env | grep DB_URL | cut -d= -f2- | tr -d '"')" -c "select jobname, schedule from cron.job"` should show `close-periods | 5 * * * *`. Use `supabase status` to find the DB URL if that pipeline doesn't parse.
- [ ] **Step 5: Commit** `feat(db): close goal periods hourly with goal points`.

---

## Done when

- `supabase db reset && supabase test db` passes all three test files on a fresh local stack.
- The `close-periods` cron job is scheduled.
- `cd Shared && swift test --disable-sandbox` still passes. Nothing in Swift changes in this plan.
