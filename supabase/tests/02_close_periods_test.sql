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
