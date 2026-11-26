-- Live Activity (plan 7): APNs updates/ends go to each activity's own push token.
alter table public.device
  add column activity_token text,
  add column activity_session_id uuid;
