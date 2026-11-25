-- The Mac marks a phone command it can't act on instead of deleting it (deleting = accepted).
-- The phone shows the reason and deletes the row; the Mac deletes unread ones after 10 s.
alter table public.session_command add column rejected_reason text;
