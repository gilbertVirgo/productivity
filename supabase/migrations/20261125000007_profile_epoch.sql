-- The auto-created profile is a placeholder: stamp it at the epoch so a device's first real edit
-- always wins last-write-wins, even when the device clock runs slightly behind the server's.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into public.profile (user_id, updated_at) values (new.id, 'epoch');
  return new;
end $$;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
