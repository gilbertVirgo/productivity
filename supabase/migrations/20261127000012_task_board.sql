-- Task board (docs/superpowers/specs/2026-11-27-task-board-design.md §3).
-- State is derived: done_at → completed; else active_at → active; else pending. deleted_at is a soft delete
-- (remote deletes aren't pulled). The current card is the latest current_at, shown only while its project is tracked.
alter table public.task
  add column active_at timestamptz,
  add column current_at timestamptz,
  add column deleted_at timestamptz;
