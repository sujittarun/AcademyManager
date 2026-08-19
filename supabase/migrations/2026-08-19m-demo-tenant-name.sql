-- ============================================================
-- 2026-08-19l · The demo tenant was called "Sports Academy"
-- scope: demo
--
-- On the operator console it sat between Gen Alpha Cricket Academy and
-- Leo Tennis Academy reading simply "Sports Academy", which is what a
-- real client would be called. `config.demo = true` is set and the
-- console does label it, but the NAME is the thing read first and it
-- said nothing.
--
-- 0012 decided deliberately that the sales demo stays VISIBLE rather
-- than hidden — hiding it would put its crashes into platform_errors()
-- with nothing to explain them. A visible demo has to be legible as a
-- demo from its name alone.
--
-- DISPLAY ONLY, verified before writing:
--   * every client that reads tenants.name filters to its own id
--     (raj's three clients, ska, CourtSync's venue lookup) and none of
--     them is `demo`;
--   * the three shared functions that return it — operator_portfolio,
--     whatsapp_reminder_stats, whatsapp_senders — are all reporting;
--   * the demo APP hardcodes its own "Sports Academy" title and is left
--     alone. It is shown to prospects, and the word "Demo" belongs on
--     the operator's dashboard, not in the product being demonstrated.
--
-- config.brand stays "Crescent Sports Academy" — that inconsistency
-- predates this file and is not its business to settle.
-- ============================================================

update tenants
   set name = 'Demo Sports Academy'
 where id = 'demo';                     -- tenant_id in the WHERE, always

do $$
declare v_name text; v_others int;
begin
  select name into v_name from tenants where id = 'demo';
  if v_name is distinct from 'Demo Sports Academy' then
    raise exception 'demo is still named %', coalesce(v_name, '(no row)');
  end if;

  -- Ids are global and this is a shared table: prove nothing else moved.
  select count(*) into v_others from tenants
   where id <> 'demo' and name = 'Demo Sports Academy';
  if v_others > 0 then
    raise exception '% other tenant(s) were renamed too', v_others;
  end if;

  -- And that it reaches the console the operator actually reads.
  perform set_config('request.jwt.claims', json_build_object('role','authenticated',
    'sub', gen_random_uuid()::text,
    'app_metadata', json_build_object('am_role','operator'))::text, true);
  -- operator_portfolio() returns one jsonb blob, not a record, so the
  -- console's row has to be dug out by key rather than selected.
  if not exists (
    select 1 from jsonb_array_elements(operator_portfolio()) e
     where e->>'tenant_id' = 'demo' and e->>'name' = 'Demo Sports Academy') then
    raise exception 'the console still shows the old name';
  end if;
  perform set_config('request.jwt.claims', null, true);

  raise notice 'demo now reads "Demo Sports Academy" on the console';
end $$;
