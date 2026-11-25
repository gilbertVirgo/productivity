-- Stint schema (spec §5). updated_at is client-set for last-write-wins sync (§6.11): no trigger touches it.

create or replace function public.is_valid_timezone(tz text) returns boolean
language sql stable as $$ select exists (select 1 from pg_timezone_names where name = tz) $$;

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
  unique (id, user_id),
  foreign key (project_id, user_id) references public.project (id, user_id) on delete cascade
);

create table public.session (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  project_id uuid not null,
  first_task_id uuid,
  planned_min int not null check (planned_min > 0),
  started_at timestamptz not null,
  ended_at timestamptz,
  end_kind text check (end_kind in ('completed', 'early')),
  early_reason text,
  device text not null default 'mac',
  unique (id, user_id),
  check (ended_at is null or ended_at >= started_at),
  check ((ended_at is null) = (end_kind is null)),
  foreign key (project_id, user_id) references public.project (id, user_id) on delete cascade,
  foreign key (first_task_id, user_id) references public.task (id, user_id) on delete set null (first_task_id)
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
  token text not null unique check (token ~ '^[A-Za-z0-9_-]{43}$')
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
create index on public.project_allow (project_id);
create index on public.session_allow (session_id);
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

revoke execute on function public.handle_new_user() from public, anon, authenticated;
