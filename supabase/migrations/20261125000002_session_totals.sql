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
