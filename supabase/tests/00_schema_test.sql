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
