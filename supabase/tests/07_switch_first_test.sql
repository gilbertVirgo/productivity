begin;
select plan(9);
select col_is_null('public', 'session', 'planned_min', 'stretches have no planned length');
select ok((select pg_get_constraintdef(oid) from pg_constraint where conname = 'session_end_kind_check') like '%switched%',
          'end_kind allows switched');
select ok((select pg_get_constraintdef(oid) from pg_constraint where conname = 'session_end_kind_check') like '%stopped%',
          'end_kind allows stopped');
select has_column('public', 'project', 'icon', 'project icon');
select has_column('public', 'project', 'short_name', 'project short name');
select col_not_null('public', 'project', 'off_mac', 'off_mac is required');
select col_default_is('public', 'project', 'off_mac', 'false', 'off_mac defaults to false');
select ok((select pg_get_constraintdef(oid) from pg_constraint where conname = 'session_command_kind_check') like '%''switch''%',
          'phone can send switch');
select ok((select pg_get_constraintdef(oid) from pg_constraint where conname = 'session_command_kind_check') like '%''break_end''%',
          'phone can send break_end');
select * from finish();
rollback;
