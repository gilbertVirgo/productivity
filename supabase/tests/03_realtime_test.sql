begin;
select plan(2);
select has_column('public', 'task', 'server_updated_at', 'editable tables carry a server pull cursor');
select is(
  (select array_agg(tablename::text order by tablename) from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public'),
  array['goal_result','point_event','project','project_allow','session','session_command','task','treat'],
  'user tables are published for realtime');
select * from finish();
rollback;
