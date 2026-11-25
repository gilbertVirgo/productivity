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
