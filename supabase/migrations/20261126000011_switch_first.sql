-- Switch-first tracking (docs/superpowers/specs/2026-11-26-switch-first-tracking-design.md §3).
-- A session row is now one stretch on one project. Old Pomodoro rows keep their planned_min and end_kind.
alter table public.session alter column planned_min drop not null;
alter table public.session drop constraint session_end_kind_check;
alter table public.session add constraint session_end_kind_check
  check (end_kind in ('completed', 'early', 'switched', 'stopped'));

alter table public.project
  add column icon text,
  add column short_name text,
  add column off_mac boolean not null default false;

-- Old kinds stay valid so an old phone's insert doesn't fail; the Mac rejects them with "Update Stint on your phone."
alter table public.session_command drop constraint session_command_kind_check;
alter table public.session_command add constraint session_command_kind_check
  check (kind in ('start', 'break', 'resume', 'end_early_request', 'switch', 'stop', 'break_start', 'break_end'));
