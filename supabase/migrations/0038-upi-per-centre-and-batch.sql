-- ============================================================
-- 0038 — a collection account per centre, and per batch
--
-- Raj coaches at venues he does not own. Several of those venues want
-- the parents' money landing in THEIR account, not his, and one batch
-- inside a venue can differ again. So "where does this fee get paid"
-- is a per-row fact, not a tenant setting.
--
-- It is also money, so it resolves in Postgres like every other money
-- rule on this platform. One resolver, called by the web app, the
-- Android app AND the reminder engine, so the UPI id a parent is asked
-- to pay and the one staff sees on screen cannot drift apart.
--
--   45  batch.upi_id      "the 7am batch collects to its own account"
--   30  centre.upi_id     "everything at BTV collects to BTV"
--   10  tenants.config.billing  the academy's own default
--
-- Generic on purpose: centres and batches are shared tables, so any
-- academy that rents space gets this for free.
-- ============================================================

alter table centres add column if not exists upi_id   text;
alter table centres add column if not exists upi_name text;
alter table batches add column if not exists upi_id   text;
alter table batches add column if not exists upi_name text;

comment on column centres.upi_id is
  'UPI VPA that fees for this centre are collected to. Null falls back to the tenant default.';
comment on column batches.upi_id is
  'UPI VPA for this batch specifically. Null falls back to the centre, then the tenant.';

-- A VPA is user-entered and ends up in a payment link, so it is worth
-- refusing an obviously malformed one at the door rather than sending a
-- parent somewhere that cannot resolve.
create or replace function is_valid_upi(p text) returns boolean
  language sql immutable as
$$ select p is null or p ~ '^[a-zA-Z0-9._%+-]{2,64}@[a-zA-Z][a-zA-Z0-9.-]{1,32}$' $$;

alter table centres drop constraint if exists centres_upi_valid;
alter table centres add constraint centres_upi_valid check (is_valid_upi(upi_id));
alter table batches drop constraint if exists batches_upi_valid;
alter table batches add constraint batches_upi_valid check (is_valid_upi(upi_id));

-- ------------------------------------------------------------
-- The resolver. Same shape as resolve_fee(): most specific wins, and
-- it reports WHERE the answer came from so a screen can say so.
-- ------------------------------------------------------------
create or replace function resolve_upi(
  p_tenant text,
  p_centre bigint default null,
  p_batch  bigint default null
) returns jsonb
  language plpgsql stable security definer set search_path = public as $$
declare
  v_vpa   text;
  v_name  text;
  v_src   text;
  cfg     jsonb;
begin
  perform assert_staff_or_service(p_tenant);

  if p_batch is not null then
    select nullif(trim(upi_id), ''), nullif(trim(upi_name), '')
      into v_vpa, v_name
      from batches where id = p_batch and tenant_id = p_tenant;
    if v_vpa is not null then v_src := 'batch'; end if;
  end if;

  if v_vpa is null and p_centre is not null then
    select nullif(trim(upi_id), ''), nullif(trim(upi_name), '')
      into v_vpa, v_name
      from centres where id = p_centre and tenant_id = p_tenant;
    if v_vpa is not null then v_src := 'centre'; end if;
  end if;

  if v_vpa is null then
    select config into cfg from tenants where id = p_tenant;
    v_vpa  := nullif(trim(coalesce(cfg->'billing'->'upiIds'->>0, '')), '');
    v_name := nullif(trim(coalesce(cfg->'billing'->>'payee', '')), '');
    if v_vpa is not null then v_src := 'academy'; end if;
  end if;

  if v_vpa is null then
    return jsonb_build_object('vpa', null, 'name', null, 'source', 'unset');
  end if;

  -- The payee name shown in the UPI app. Falls back to the academy's
  -- billing name so a parent never sees a blank "paying to".
  if v_name is null then
    select nullif(trim(coalesce(config->'billing'->>'payee', '')), '')
      into v_name from tenants where id = p_tenant;
  end if;

  return jsonb_build_object('vpa', v_vpa, 'name', v_name, 'source', v_src);
end $$;

revoke execute on function resolve_upi(text, bigint, bigint) from public, anon;
grant  execute on function resolve_upi(text, bigint, bigint) to authenticated, service_role;

-- ------------------------------------------------------------
-- The reminder queue carries the resolved account, so the engine, the
-- web app and the Android app all quote the same one. Adding columns
-- to a TABLE-returning function needs a drop; nothing depends on it in
-- the catalogue (tenant_health calls it from a plpgsql body, which is
-- not a tracked dependency).
-- ------------------------------------------------------------
drop function if exists reminder_queue(text, date);

create or replace function reminder_queue(p_tenant text, p_on date default null)
  returns table (
    enrollment_id bigint,
    member_id     bigint,
    member_name   text,
    parent_name   text,
    phone         text,
    centre        text,
    batch         text,
    sport         text,
    due_date      date,
    days_since    int,
    stage         text,
    amount        numeric,
    months        int,
    fee_source    text,
    whatsapp_status text,
    blocked_reason  text,
    already_sent    boolean,
    last_sent_at     timestamptz,
    last_sent_status text,
    last_sent_channel text,
    upi_id     text,
    upi_name   text,
    upi_source text
  )
  language sql stable security definer set search_path = public as $$
  with today as (select coalesce(p_on, ist_today()) as d),
  base as (
    select e.id as enrollment_id, e.member_id, m.name as member_name,
           m.parent_name,
           coalesce(nullif(m.parent_phone,''), nullif(m.phone,'')) as phone,
           c.short_name as centre, b.name as batch, e.sport,
           e.renewal_on as due_date,
           ((select d from today) - e.renewal_on) as days_since,
           e.plan_months as months,
           m.whatsapp_status,
           resolve_fee(e.tenant_id, e.member_id, e.centre_id, e.sport, e.batch_id,
                       e.plan_months, e.custom_amount) as fee,
           resolve_upi(e.tenant_id, e.centre_id, e.batch_id) as upi
      from enrollments e
      join members m on m.id = e.member_id
      join centres c on c.id = e.centre_id
      left join batches b on b.id = e.batch_id
     where e.tenant_id = p_tenant
       and e.status = 'active'
       and m.status <> 'discontinued'
       and e.renewal_on is not null
  ),
  last_sent as (
    select distinct on (r.enrollment_id)
           r.enrollment_id, r.created_at, r.status, r.channel
      from reminder_events r
     where r.tenant_id = p_tenant and r.status <> 'void'
     order by r.enrollment_id, r.created_at desc
  )
  select
    base.enrollment_id, base.member_id, base.member_name, base.parent_name,
    base.phone, base.centre, base.batch, base.sport, base.due_date, base.days_since,
    case
      when base.days_since = -2 then 'heads_up'
      when base.days_since = 0  then 'due'
      else 'overdue'
    end as stage,
    (base.fee->>'amount')::numeric as amount,
    base.months,
    base.fee->>'source' as fee_source,
    base.whatsapp_status,
    case
      when base.phone is null or length(regexp_replace(base.phone,'\D','','g')) < 10
        then 'missing_phone'
      when base.whatsapp_status = 'wrong_number' then 'wrong_phone_number'
      when base.whatsapp_status = 'opted_out'    then 'whatsapp_opted_out'
      when base.days_since >= 15                 then 'overdue_15_days'
      when (base.fee->>'amount') is null         then 'fee_not_set'
      else null
    end as blocked_reason,
    exists (
      select 1 from reminder_events r
       where r.tenant_id = p_tenant
         and r.enrollment_id = base.enrollment_id
         and r.ist_date = (select d from today)
         and r.status <> 'void'
    ) as already_sent,
    ls.created_at as last_sent_at,
    ls.status     as last_sent_status,
    ls.channel    as last_sent_channel,
    base.upi->>'vpa'    as upi_id,
    base.upi->>'name'   as upi_name,
    base.upi->>'source' as upi_source
  from base
  left join last_sent ls on ls.enrollment_id = base.enrollment_id
  where base.days_since = -2
     or base.days_since = 0
     or base.days_since = 5
     or (base.days_since between 7 and 14)
     or base.days_since >= 15
  order by base.days_since desc, base.member_name
$$;

revoke execute on function reminder_queue(text, date) from public, anon;
grant  execute on function reminder_queue(text, date) to authenticated, service_role;

-- ------------------------------------------------------------
-- Setting a collection account. A guarded RPC rather than a raw PATCH,
-- so both clients validate identically and the change is audited.
-- ------------------------------------------------------------
create or replace function set_collection_account(
  p_tenant text,
  p_kind   text,              -- 'centre' | 'batch'
  p_id     bigint,
  p_upi    text default null,
  p_name   text default null
) returns jsonb
  language plpgsql security definer set search_path = public as $$
declare v_upi text := nullif(trim(coalesce(p_upi, '')), '');
begin
  perform assert_staff_or_service(p_tenant);
  if p_kind not in ('centre', 'batch') then
    raise exception 'Unknown kind "%".', p_kind using errcode = 'check_violation';
  end if;
  if not is_valid_upi(v_upi) then
    raise exception 'That does not look like a UPI id. It should read like name@bank.'
      using errcode = 'check_violation';
  end if;

  if p_kind = 'centre' then
    update centres set upi_id = v_upi, upi_name = nullif(trim(coalesce(p_name,'')), '')
     where id = p_id and tenant_id = p_tenant;
  else
    update batches set upi_id = v_upi, upi_name = nullif(trim(coalesce(p_name,'')), '')
     where id = p_id and tenant_id = p_tenant;
  end if;
  if not found then
    raise exception 'That % does not belong to this academy.', p_kind using errcode = 'no_data_found';
  end if;

  return resolve_upi(p_tenant,
    case when p_kind = 'centre' then p_id else null end,
    case when p_kind = 'batch'  then p_id else null end);
end $$;

revoke execute on function set_collection_account(text, text, bigint, text, text) from public, anon;
grant  execute on function set_collection_account(text, text, bigint, text, text) to authenticated, service_role;
