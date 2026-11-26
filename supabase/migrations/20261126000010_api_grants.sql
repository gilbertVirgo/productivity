-- Hosted projects no longer expose new public tables to the Data API by default
-- (the local stack still does), so the apps got "permission denied for table".
-- Grant explicitly; RLS still decides which rows each user sees. anon gets no
-- table access: the share page only calls rpc/share_data.
grant select, insert, update, delete on all tables in schema public to authenticated;
grant all on all tables in schema public to service_role;
grant usage, select on all sequences in schema public to authenticated, service_role;

alter default privileges for role postgres in schema public
  grant select, insert, update, delete on tables to authenticated;
alter default privileges for role postgres in schema public
  grant all on tables to service_role;
alter default privileges for role postgres in schema public
  grant usage, select on sequences to authenticated, service_role;
