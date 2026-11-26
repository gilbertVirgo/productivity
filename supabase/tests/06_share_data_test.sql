begin;
select plan(19);

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
  'hours:2.00:on_track,tasks:1:on_track', 'weekly goals with live actuals and status');
select is((select string_agg((d ->> 'date') || '=' || (d ->> 'status'), ',')
             from jsonb_array_elements(pg_temp.share() #> '{projects,0,days}') d),
  '2026-11-23=met,2026-11-24=missed,2026-11-25=on_track,2026-11-26=upcoming,2026-11-27=upcoming',
  'daily results on goal days only; today in progress; future upcoming');
select is((select string_agg((r ->> 'period') || ':' || (r ->> 'period_start') || ':' || (r ->> 'met'), ',')
             from jsonb_array_elements(pg_temp.share() #> '{projects,0,last_week}') r),
  'week:2026-11-16:false,day:2026-11-20:true', 'last week from goal_result, this project only');

update public.project set created_at = '2026-11-24 15:00+00' where id = '20000000-0000-0000-0000-000000000001';
select is((select string_agg(d ->> 'date', ',') from jsonb_array_elements(pg_temp.share() #> '{projects,0,days}') d),
  '2026-11-24,2026-11-25,2026-11-26,2026-11-27', 'no daily results before the project existed');

select ok(has_function_privilege('anon', 'public.share_data(text)', 'execute'), 'anon can call share_data');
select ok(not has_function_privilege('anon', 'public.share_data_at(text, timestamptz)', 'execute'), 'anon cannot pick the clock');

select * from finish();
rollback;
