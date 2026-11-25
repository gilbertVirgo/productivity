begin;
select plan(1);
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000e1', 'epoch@test.local');
select is((select updated_at from public.profile where user_id = '00000000-0000-0000-0000-0000000000e1'),
          'epoch'::timestamptz, 'auto-created profile is stamped at the epoch so the first real edit wins');
select * from finish();
rollback;
