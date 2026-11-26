-- Friends share page (spec §6.10). The static page calls rpc/share_data with the public anon key;
-- security definer stands in for the spec's service-role edge function. Returns only aliases, goals and results.

-- Port of Core.goalStatus (Shared/Sources/Core/Goals.swift). Keep the two in lockstep (spec §8).
create or replace function public.goal_status(p_target numeric, p_actual numeric, p_elapsed numeric, p_closed boolean)
returns text language sql immutable as $$
  select case when p_actual >= p_target then 'met'
              when p_closed then 'missed'
              when p_actual >= p_target * p_elapsed then 'on_track'
              else 'behind' end
$$;

create or replace function public.share_data_at(p_token text, p_now timestamptz)
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
  if tz is null then return null; end if;

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
      -- Shown hours round down, so a goal that isn't met never displays as reaching its target.
      goals := goals || jsonb_build_object('kind', 'hours', 'target', p.weekly_hours_goal,
        'actual', round(floor(secs / 360.0) / 10, 1), 'status', goal_status(p.weekly_hours_goal * 3600, secs, elapsed, false));
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
            'actual', round(floor(secs / 360.0) / 10, 1),
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
    -- Last finished session on a shared project: running sessions aren't counted, so they don't move it either.
    'updated_at', (select max(s.ended_at) from session s join project pr on pr.id = s.project_id
                    where s.user_id = uid and pr.shared and pr.archived_at is null),
    'projects', projects);
end $$;

-- The page's entry point: the clock is always now().
create or replace function public.share_data(p_token text)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select public.share_data_at(p_token, now())
$$;

revoke execute on function public.share_data_at(text, timestamptz) from public, anon, authenticated;
revoke execute on function public.share_data(text) from public;
grant execute on function public.share_data(text) to anon, authenticated;
