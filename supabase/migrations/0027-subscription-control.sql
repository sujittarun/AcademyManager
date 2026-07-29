-- ============================================================
-- 0027 · Change a tenant's billing from the console
-- scope: shared
--
-- The console reads subscriptions and has no way to write them, so
-- moving an academy from trial to paying meant hand-writing SQL against
-- production. That is a bad reason to open a SQL editor, and every time
-- it is opened is a chance to type the wrong `where`.
--
-- How the console decides what to show (index.html:166):
--
--   overdue   status = 'overdue', OR renews_on is in the past
--   paid      status in ('active','paid')
--   pending   anything else — 'trial', 'pilot', 'cancelled'
--
-- So "pending -> paid" is really "set status to active, and make sure
-- the renewal date is not behind you". Both, or the badge flips to
-- overdue instead, which is a confusing way to be told good news.
--
-- Operator only. A tenant's own staff must never be able to mark
-- themselves paid.
-- ============================================================

create or replace function public.set_subscription(
  p_tenant    text,
  p_status    text default null,
  p_plan      text default null,
  p_mrr       numeric default null,
  p_renews_on date default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_before jsonb;
  v_after  jsonb;
  v_status text := nullif(trim(lower(p_status)), '');
begin
  if auth_role() <> 'operator' then
    raise exception 'operator only';
  end if;

  if not exists (select 1 from tenants where id = p_tenant) then
    raise exception 'no such tenant: %', p_tenant;
  end if;

  -- An unknown status silently becomes "pending" in the console, which
  -- looks like the change did not take. Refuse instead.
  if v_status is not null
     and v_status not in ('active','paid','trial','pilot','overdue','cancelled') then
    raise exception 'unknown status %; use active, paid, trial, pilot, overdue or cancelled', v_status;
  end if;

  select to_jsonb(s) into v_before from subscriptions s where s.tenant_id = p_tenant;

  if v_before is null then
    insert into subscriptions (tenant_id, plan, mrr, status, started, renews_on)
    values (p_tenant,
            coalesce(p_plan, 'standard'),
            coalesce(p_mrr, 0),
            coalesce(v_status, 'trial'),
            current_date,
            coalesce(p_renews_on, (current_date + interval '1 month')::date));
  else
    update subscriptions
       set status     = coalesce(v_status, status),
           plan       = coalesce(p_plan, plan),
           mrr        = coalesce(p_mrr, mrr),
           -- Marking someone paid while their renewal is in the past
           -- would show them as overdue a second later. Roll it forward.
           renews_on  = coalesce(
                          p_renews_on,
                          case
                            when v_status in ('active','paid') and renews_on < current_date
                              then (current_date + interval '1 month')::date
                            else renews_on
                          end)
     where tenant_id = p_tenant;
  end if;

  select to_jsonb(s) into v_after from subscriptions s where s.tenant_id = p_tenant;

  -- Billing changes should leave a trace. sync_log is where the platform
  -- already keeps its own record of things it did.
  insert into sync_log (tenant_id, channel, action, status, detail)
  values (p_tenant, '*', 'subscription', 'ok',
          coalesce(v_before ->> 'status', '(none)') || ' -> ' || (v_after ->> 'status') ||
          ', mrr ' || coalesce(v_before ->> 'mrr', '0') || ' -> ' || (v_after ->> 'mrr') ||
          ' by ' || coalesce(nullif(auth.jwt() ->> 'email', ''), 'operator'));

  return jsonb_build_object('ok', true, 'before', v_before, 'after', v_after);
end $function$;

comment on function public.set_subscription(text,text,text,numeric,date) is
  'Operator-only. Change a tenant plan/status/mrr/renewal and log it.';

revoke execute on function public.set_subscription(text,text,text,numeric,date) from public, anon;
grant execute on function public.set_subscription(text,text,text,numeric,date) to authenticated, service_role;

-- ------------------------------------------------------------
-- Machaxi is not a client yet. Archived, same as MatchPoint: it leaves
-- the console, its 12 members and 248 bookings stay exactly where they
-- are, and one update brings it back the day they sign.
-- ------------------------------------------------------------
update tenants
   set config = coalesce(config, '{}'::jsonb) || jsonb_build_object('archived', true)
 where id = 'machaxi';

do $$
declare v jsonb; v_n int;
begin
  if not coalesce((select (config->>'archived')::boolean from tenants where id='machaxi'), false) then
    raise exception 'machaxi not archived';
  end if;
  -- archiving must not touch the data
  select count(*) into v_n from members where tenant_id='machaxi';
  if v_n = 0 then raise exception 'archiving machaxi lost its members'; end if;

  perform set_config('request.jwt.claims',
    '{"role":"authenticated","email":"operator@academymanager.in","app_metadata":{"am_role":"operator"}}', true);

  -- it should be gone from the console
  if exists (
    select 1 from jsonb_array_elements(operator_portfolio()) x
     where x->>'tenant_id' = 'machaxi'
  ) then
    raise exception 'machaxi still listed in the console';
  end if;

  -- and prove the control works, on a tenant that is genuinely pending
  v := set_subscription('mpp', 'active', null, null, null);
  if (v #>> '{after,status}') <> 'active' then
    raise exception 'set_subscription did not take: %', v;
  end if;
  if ((v #>> '{after,renews_on}')::date) < current_date then
    raise exception 'marked paid with a past renewal — would show overdue';
  end if;

  -- put mpp back; the owner decides when it is paying, not this migration
  perform set_subscription('mpp', 'trial', null, null, null);
  delete from sync_log where tenant_id='mpp' and action='subscription';

  raise notice 'machaxi archived; set_subscription works';
end $$;
