-- ============================================================
-- 2026-08-11h · anon needs USAGE on the genalpha schema
-- scope: shared
--
-- 2026-08-10a did `revoke all on schema genalpha from public, anon`,
-- which was right for tables and wrong for the two functions a parent
-- must reach before they have an account. Without schema USAGE, anon
-- cannot resolve anything inside genalpha — the EXECUTE grants on
-- submit_admission_form and peek_next_admission_reg_no were unreachable
-- and both returned 401. The public admission form was broken.
--
-- USAGE on a schema is permission to NAME things in it, not to read
-- them. Every table in genalpha keeps `revoke all ... from anon`, so
-- this grants the ability to call two functions and nothing else.
-- Verified below rather than assumed.
-- ============================================================

grant usage on schema genalpha to anon;

-- and make certain nothing else came with it
revoke all on all tables in schema genalpha from anon;
revoke all on all sequences in schema genalpha from anon;
alter default privileges in schema genalpha revoke all on tables from anon;

do $$
declare n int;
begin
  if not has_schema_privilege('anon','genalpha','usage') then
    raise exception 'anon still cannot use the genalpha schema';
  end if;

  -- the two public-form functions must be reachable
  if not has_function_privilege('anon','genalpha.peek_next_admission_reg_no()','execute') then
    raise exception 'anon cannot execute peek_next_admission_reg_no';
  end if;

  -- and approve_admission must NOT be
  if has_function_privilege('anon',
       'genalpha.approve_admission(uuid,text,text)','execute') then
    raise exception 'anon can execute approve_admission';
  end if;

  -- no table in the schema may be readable by anon
  select count(*) into n
    from information_schema.tables t
   where t.table_schema='genalpha'
     and has_table_privilege('anon', 'genalpha.'||quote_ident(t.table_name), 'select');
  if n > 0 then
    raise exception '% genalpha tables/views are readable by anon', n;
  end if;

  raise notice 'anon may name the schema and call two functions; reads nothing';
end $$;
