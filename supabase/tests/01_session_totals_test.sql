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
