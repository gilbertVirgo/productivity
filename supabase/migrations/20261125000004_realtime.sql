-- Server-stamped pull cursor. updated_at is client-supplied, so an offline edit pushed late would land
-- behind another device's watermark; server_updated_at is always now() at write time.
create function public.stamp_server_updated_at() returns trigger language plpgsql as $$
begin new.server_updated_at := now(); return new; end $$;

do $$
declare t text;
begin
  foreach t in array array['project', 'project_allow', 'task', 'treat', 'session'] loop
    execute format('alter table public.%I add column server_updated_at timestamptz not null default now()', t);
    execute format('create index on public.%I (user_id, server_updated_at)', t);
    execute format('create trigger stamp_server_updated_at before insert or update on public.%I
                    for each row execute function public.stamp_server_updated_at()', t);
  end loop;
end $$;

alter publication supabase_realtime add table
  public.project, public.project_allow, public.task, public.treat, public.session,
  public.point_event, public.goal_result, public.session_command, public.profile;
