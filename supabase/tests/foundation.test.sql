begin;

create extension if not exists pgtap with schema extensions;
set local search_path to public, extensions;

select plan(3);

select is(
  current_setting('server_version_num')::integer / 10000,
  17,
  'the local database runs PostgreSQL 17'
);

create table public.hu003_privilege_probe (id uuid primary key);

select ok(
  not has_table_privilege('anon', 'public.hu003_privilege_probe', 'SELECT, INSERT, UPDATE, DELETE'),
  'anon needs an explicit grant on a new public table'
);

select ok(
  not has_table_privilege('authenticated', 'public.hu003_privilege_probe', 'SELECT, INSERT, UPDATE, DELETE'),
  'authenticated needs an explicit grant on a new public table'
);

select * from finish();

rollback;
