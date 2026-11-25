-- Profile changes are not consumed over realtime (pulled on the sync timer); stop fanning them out.
alter publication supabase_realtime drop table public.profile;
