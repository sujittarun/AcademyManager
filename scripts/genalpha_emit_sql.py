#!/usr/bin/env python3
"""
Emit the GenAlpha merge migrations from the PROVEN transform output.

The transform (genalpha_transform.py) is validated offline against
GenAlpha's own student_paid_through_date(). This turns its output into
staged, ledgered SQL. It generates files; it applies nothing.

Staging is deliberate — each stage is independently verifiable and each
one asserts before it commits:

  A  schema + side table + tenant config
  B  centres, batches, members, student_details, enrollments   (identity + money)
  C  payments, applications, expenses, attendance              (history)
  D  member_timeline                                           (bulk, 3k rows)
  E  compatibility views                                       (the app keeps working)

The uuid -> bigint mapping is resolved by a plpgsql loop that inserts a
member and its side-table row together, capturing the new id via
RETURNING. Never by joining on name — GenAlpha has repeated names.
"""
import json, os, sys

SRC = "/tmp/genalpha-transform-out"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "supabase", "migrations")
T = "genalpha"


def load(n):
    with open(os.path.join(SRC, n + ".json")) as f:
        return json.load(f)


def lit(v):
    """SQL literal."""
    if v is None or v == "":
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    return "'" + str(v).replace("'", "''") + "'"


def jsonb(obj):
    return "'" + json.dumps(obj, default=str).replace("'", "''") + "'::jsonb"


def write(name, body):
    p = os.path.abspath(os.path.join(OUT, name))
    with open(p, "w") as f:
        f.write(body)
    print(f"  {name:<44}{len(body)//1024:>5} KB")
    return p


# ---------------------------------------------------------------- A
def stage_a():
    return f"""-- ============================================================
-- 2026-08-10a · GenAlpha merge, stage A: the container
-- scope: shared
--
-- GenAlpha stops being a federated tenant and becomes a native one. Its
-- data moves out of project hwxhigwaklzedxufwedv and into this database.
--
-- Nothing tenant-specific goes into public. The shared schema stays
-- generic; everything GenAlpha-only lives in its own schema, which is
-- the same pattern `backup` already uses here. If GenAlpha ever leaves,
-- `drop schema genalpha cascade` is the whole cleanup.
--
-- Source of truth: _archive/genalpha-premerge-2026-08-10/ — a verified
-- export of all 18 tables, 8,868 rows, plus the schema and GenAlpha's
-- own student_paid_through_date() for every student.
-- ============================================================

create schema if not exists genalpha;
comment on schema genalpha is
  'GenAlpha-only structures. The shared public schema stays generic; anything true of only this tenant lives here.';
revoke all on schema genalpha from public, anon;
grant usage on schema genalpha to authenticated, service_role;

-- The side table. PLATFORM.md: "Tenant-specific field -> a tenant-owned
-- table keyed on the shared row's id. Not a new column on members."
--
-- legacy_uuid is load-bearing, not archaeology: GenAlpha is uuid-keyed
-- and the platform is bigint, so this column is the bridge that lets the
-- existing app keep sending uuids after the cutover.
create table if not exists genalpha.student_details (
  member_id     bigint primary key references public.members(id) on delete cascade,
  legacy_uuid   uuid unique not null,
  reg_no        bigint,
  time_slot     text,
  jersey_size   text,
  jersey_pairs  integer,
  payment_method text,
  payment_upi_id text,
  payment_reference text,
  fee_plan      text,
  coaching_fee  numeric,
  admission_fee numeric,
  jersey_amount numeric,
  total_fee_amount numeric,
  fee_pause_days integer,
  rejoined_at   date,
  admission_id  uuid,
  added_by      text,
  updated_by    text,
  filled_by     text,
  payment_status text,
  fees_paid     boolean,
  amount_paid   numeric,
  renewals      jsonb,
  extra         jsonb,
  created_at    timestamptz default now()
);
create index if not exists genalpha_student_details_uuid_idx
  on genalpha.student_details(legacy_uuid);

alter table genalpha.student_details enable row level security;
-- Same shape as the rest of the platform: staff of this tenant only.
create policy genalpha_details_staff on genalpha.student_details
  for all to authenticated
  using (auth_role() in ('staff','operator') and (auth_role()='operator' or auth_tenant()='genalpha'))
  with check (auth_role() in ('staff','operator') and (auth_role()='operator' or auth_tenant()='genalpha'));
revoke all on genalpha.student_details from public, anon;
grant select, insert, update, delete on genalpha.student_details to authenticated, service_role;

-- GenAlpha is no longer federated: its rows live here now, so
-- operator_portfolio() must read them natively rather than fall back to
-- the newest tenant_rollup event.
update tenants
   set config = (coalesce(config,'{{}}'::jsonb) - 'federated')
              || jsonb_build_object(
                   'sport','Cricket',
                   'city','Bengaluru',
                   'modules', jsonb_build_object('coaching',true,'whatsapp',true,
                                                 'booking',false,'courts',false,'payouts',false),
                   'features', jsonb_build_object('admissionsAI',true))
 where id = 'genalpha';

do $$
begin
  if (select config ? 'federated' from tenants where id='genalpha') then
    raise exception 'genalpha is still marked federated';
  end if;
  if to_regclass('genalpha.student_details') is null then
    raise exception 'genalpha.student_details was not created';
  end if;
  raise notice 'stage A ok';
end $$;
"""


# ---------------------------------------------------------------- B
def stage_b():
    members = load("members")
    details = {d["member_ref"]: d for d in load("genalpha_student_details")}
    enrolls = {e["member_ref"]: e for e in load("enrollments")}
    batches = load("batches")

    rows = []
    for m in members:
        mid = m["_id"]
        d = details[mid]
        e = enrolls[mid]
        known = {"member_ref", "legacy_uuid", "reg_no", "time_slot", "jersey_size",
                 "jersey_pairs", "payment_method", "payment_upi_id", "payment_reference",
                 "fee_plan", "coaching_fee", "admission_fee", "jersey_amount",
                 "total_fee_amount", "fee_pause_days", "rejoined_at", "admission_id",
                 "added_by", "updated_by", "filled_by", "payment_status", "fees_paid",
                 "amount_paid", "renewals"}
        extra = {k: v for k, v in d.items() if k not in known}
        rows.append({
            "m": {k: m.get(k) for k in
                  ("name", "phone", "parent_name", "parent_phone", "alt_phone", "school",
                   "grade", "address", "joined", "status", "discontinued_on", "program",
                   "notes", "whatsapp_status")},
            "d": {k: d.get(k) for k in known if k not in ("member_ref",)},
            "e": {k: e.get(k) for k in ("batch_ref", "sport", "plan_months", "joined_on",
                                        "renewal_on", "status", "discontinued_on")},
        })

    bl = ",\n    ".join(
        f"({lit(b['code'])}, {lit(b['name'])}, {lit(b['_derived_from_time_slot'])}, {b['sort']})"
        for b in batches)

    return f"""-- ============================================================
-- 2026-08-10b · GenAlpha merge, stage B: identity and money
-- scope: shared
--
-- 81 members, 81 enrollments, 5 batches, 1 centre.
--
-- renewal_on is NOT derived here. It comes from GenAlpha's own
-- student_paid_through_date(), exported per student before the merge.
-- The first attempt derived it from students.renewals and called 34 of
-- 47 active students overdue when the real answer is 12 — which would
-- have had reminder_queue() chase 34 paid-up families on day one. The
-- tenant's money logic already existed and was right; this reads it.
--
-- The uuid -> bigint mapping is resolved by inserting each member and
-- its side-table row together and capturing the new id via RETURNING.
-- Never by joining on name: GenAlpha has repeated names.
-- ============================================================

insert into centres (tenant_id, code, name, short_name, active, sort)
values ('{T}', 'GA', 'GenAlpha Cricket Academy', 'GenAlpha', true, 1)
on conflict do nothing;

insert into batches (tenant_id, centre_id, code, name, sport, days, start_time, end_time, active, sort)
select '{T}', (select id from centres where tenant_id='{T}' and code='GA'),
       v.code, v.name, 'cricket', array[1,2,3,4,5], time '06:00', time '07:30', true, v.sort
  from (values
    {bl}
  ) as v(code, name, slot, sort)
on conflict do nothing;

do $$
declare r jsonb; v_member bigint; v_batch bigint; n int := 0;
begin
  for r in select * from jsonb_array_elements({jsonb(rows)})
  loop
    insert into members (tenant_id, name, phone, parent_name, parent_phone, alt_phone,
                         school, grade, address, joined, status, discontinued_on,
                         program, notes, whatsapp_status)
    values ('{T}',
      r->'m'->>'name', r->'m'->>'phone', r->'m'->>'parent_name', r->'m'->>'parent_phone',
      r->'m'->>'alt_phone', r->'m'->>'school', r->'m'->>'grade', r->'m'->>'address',
      (r->'m'->>'joined')::date, r->'m'->>'status', (r->'m'->>'discontinued_on')::date,
      r->'m'->>'program', r->'m'->>'notes', r->'m'->>'whatsapp_status')
    returning id into v_member;

    insert into genalpha.student_details (
      member_id, legacy_uuid, reg_no, time_slot, jersey_size, jersey_pairs,
      payment_method, payment_upi_id, payment_reference, fee_plan, coaching_fee,
      admission_fee, jersey_amount, total_fee_amount, fee_pause_days, rejoined_at,
      admission_id, added_by, updated_by, filled_by, payment_status, fees_paid,
      amount_paid, renewals, extra)
    values (v_member, (r->'d'->>'legacy_uuid')::uuid,
      (r->'d'->>'reg_no')::bigint, r->'d'->>'time_slot', r->'d'->>'jersey_size',
      (r->'d'->>'jersey_pairs')::int, r->'d'->>'payment_method', r->'d'->>'payment_upi_id',
      r->'d'->>'payment_reference', r->'d'->>'fee_plan', (r->'d'->>'coaching_fee')::numeric,
      (r->'d'->>'admission_fee')::numeric, (r->'d'->>'jersey_amount')::numeric,
      (r->'d'->>'total_fee_amount')::numeric, (r->'d'->>'fee_pause_days')::int,
      (r->'d'->>'rejoined_at')::date, (r->'d'->>'admission_id')::uuid,
      r->'d'->>'added_by', r->'d'->>'updated_by', r->'d'->>'filled_by',
      r->'d'->>'payment_status', (r->'d'->>'fees_paid')::boolean,
      (r->'d'->>'amount_paid')::numeric, r->'d'->'renewals', r->'d'->'extra');

    select id into v_batch from batches
     where tenant_id='{T}' and code = 'GA-' || upper(regexp_replace(coalesce(r->'d'->>'time_slot',''), '[^A-Za-z0-9]', '', 'g'));

    insert into enrollments (tenant_id, member_id, centre_id, batch_id, sport,
                             plan_months, joined_on, renewal_on, status, discontinued_on)
    values ('{T}', v_member,
      (select id from centres where tenant_id='{T}' and code='GA'),
      v_batch, 'cricket',
      coalesce((r->'e'->>'plan_months')::int, 1),
      (r->'e'->>'joined_on')::date,
      (r->'e'->>'renewal_on')::date,
      r->'e'->>'status',
      (r->'e'->>'discontinued_on')::date);
    n := n + 1;
  end loop;
  raise notice 'inserted % members', n;
end $$;

-- ------------------------------------------------------------
-- Checks. Each one CAN fail.
-- ------------------------------------------------------------
do $$
declare n int; v_over int;
begin
  select count(*) into n from members where tenant_id='{T}';
  if n <> 81 then raise exception 'expected 81 members, got %', n; end if;

  select count(*) into n from enrollments where tenant_id='{T}';
  if n <> 81 then raise exception 'expected 81 enrollments, got %', n; end if;

  select count(*) into n from genalpha.student_details;
  if n <> 81 then raise exception 'expected 81 side rows, got %', n; end if;

  -- the uuid bridge must be total, or the app cannot be pointed here
  if exists (select 1 from members m where m.tenant_id='{T}'
               and not exists (select 1 from genalpha.student_details d where d.member_id=m.id)) then
    raise exception 'a member has no legacy_uuid — the compatibility views would 404';
  end if;

  -- every enrollment reaches a batch and a centre
  if exists (select 1 from enrollments where tenant_id='{T}' and (batch_id is null or centre_id is null)) then
    raise exception 'an enrollment has no batch or centre';
  end if;

  -- THE money check: GenAlpha's own function says 12 active students are
  -- overdue. If this lands differently, reminder_queue() will chase the
  -- wrong families and we stop here.
  select count(*) into v_over from enrollments
   where tenant_id='{T}' and status='active' and renewal_on < current_date;
  if v_over <> 12 then
    raise exception 'expected 12 overdue active enrollments (GenAlpha''s own figure), got %', v_over;
  end if;

  if (select count(*) from cross_tenant_integrity()) <> 0 then
    raise exception 'cross_tenant_integrity() is non-empty';
  end if;

  raise notice 'stage B ok: 81 members, 81 enrollments, % overdue', v_over;
end $$;
"""


# ---------------------------------------------------------------- C/D
def uuid_of():
    """my synthetic member_ref -> GenAlpha's legacy uuid"""
    return {d["member_ref"]: d["legacy_uuid"] for d in load("genalpha_student_details")}


def stage_c():
    u = uuid_of()
    pays = load("payments")
    apps = load("applications")
    exps = load("expenses")
    att  = load("attendance")

    prows = [{**{k: p.get(k) for k in ("amount","mode","on_date","months","kind",
                                        "status","ref","note","proof_path","collected_by")},
              "uu": u[p["member_ref"]]} for p in pays]
    arows = [{k: a.get(k) for k in ("name","phone","parent_name","parent_phone","dob",
                                     "gender","school","sport","created_at")} for a in apps]
    erows = [{k: e.get(k) for k in ("category","payee","detail","amount","mode","on_date")} for e in exps]
    trows = [{k: a.get(k) for k in ("date","person_id")} for a in att]

    return f"""-- ============================================================
-- 2026-08-10c · GenAlpha merge, stage C: history
-- scope: shared
--
-- 130 payments, 102 applications, 48 expenses, 1,451 attendance rows.
--
-- Payments are inserted directly rather than through
-- record_fee_payment(). That function also rolls renewal_on forward and
-- closes a reminder_events row — correct for a live payment, wrong for
-- history, because it would move every renewal date stage B just set
-- from GenAlpha's own paid-through figures. Future payments go through
-- the function; these are the past.
--
-- Attendance uses the flat `attendance` table with kind='member'.
-- person_id is TEXT on the platform, so GenAlpha's student uuid drops in
-- with no remapping at all.
-- ============================================================

insert into payments (tenant_id, member_id, centre_id, sport, name, type, amount, mode,
                      on_date, months, kind, status, ref, note, proof_path, collected_by)
select '{T}', d.member_id,
       (select id from centres where tenant_id='{T}' and code='GA'),
       'cricket', m.name, 'Fee',
       (x->>'amount')::int, x->>'mode', (x->>'on_date')::date,
       (x->>'months')::int, x->>'kind', x->>'status',
       -- payments_ref_unique is (tenant_id, ref). Several GenAlpha
       -- payments have an empty ref, and '' collides where NULL does not.
       nullif(x->>'ref',''), x->>'note', x->>'proof_path', x->>'collected_by'
  from jsonb_array_elements({jsonb(prows)}) x
  join genalpha.student_details d on d.legacy_uuid = (x->>'uu')::uuid
  join members m on m.id = d.member_id;

insert into applications (tenant_id, name, phone, parent_name, parent_phone, dob,
                          gender, school, sport, created_at)
select '{T}', x->>'name', x->>'phone', x->>'parent_name', x->>'parent_phone',
       (x->>'dob')::date, x->>'gender', x->>'school', 'cricket',
       coalesce((x->>'created_at')::timestamptz, now())
  from jsonb_array_elements({jsonb(arows)}) x;

insert into expenses (tenant_id, category, payee, detail, amount, mode, on_date)
select '{T}', x->>'category', x->>'payee', x->>'detail',
       (x->>'amount')::numeric, x->>'mode', (x->>'on_date')::date
  from jsonb_array_elements({jsonb(erows)}) x;

insert into attendance (tenant_id, date, kind, person_id, present)
select '{T}', (x->>'date')::date, 'member', x->>'person_id', true
  from jsonb_array_elements({jsonb(trows)}) x
on conflict do nothing;

do $$
declare n int; s numeric;
begin
  select count(*) into n from payments where tenant_id='{T}';
  if n <> 130 then raise exception 'expected 130 payments, got %', n; end if;

  select sum(amount) into s from payments where tenant_id='{T}';
  if s <> 492551 then raise exception 'money mismatch: expected 492551, got %', s; end if;

  select count(*) into n from applications where tenant_id='{T}';
  if n <> 102 then raise exception 'expected 102 applications, got %', n; end if;

  select count(*) into n from expenses where tenant_id='{T}';
  if n <> 48 then raise exception 'expected 48 expenses, got %', n; end if;

  select count(*) into n from attendance where tenant_id='{T}';
  if n < 1400 then raise exception 'expected ~1451 attendance rows, got %', n; end if;

  -- every payment reaches a real member of THIS tenant
  if exists (select 1 from payments p where p.tenant_id='{T}'
               and not exists (select 1 from members m where m.id=p.member_id and m.tenant_id='{T}')) then
    raise exception 'a payment points at a member outside genalpha';
  end if;

  if (select count(*) from cross_tenant_integrity()) <> 0 then
    raise exception 'cross_tenant_integrity() is non-empty';
  end if;

  raise notice 'stage C ok: 130 payments totalling %, 102 applications, 48 expenses', s;
end $$;
"""


def stage_d():
    u = uuid_of()
    tl = load("member_timeline")
    rows = [{"uu": u[t["member_ref"]], "kind": t.get("kind"), "title": t.get("title"),
             "body": t.get("body"), "at": t.get("at"), "meta": t.get("meta")} for t in tl]
    chunks = [rows[i:i+800] for i in range(0, len(rows), 800)]
    body = "\n".join(f"""insert into member_timeline (tenant_id, member_id, kind, title, body, at, meta)
select '{T}', d.member_id, x->>'kind', x->>'title', x->>'body',
       coalesce((x->>'at')::timestamptz, now()), x->'meta'
  from jsonb_array_elements({jsonb(c)}) x
  join genalpha.student_details d on d.legacy_uuid = (x->>'uu')::uuid;
""" for c in chunks)

    return f"""-- ============================================================
-- 2026-08-10d · GenAlpha merge, stage D: the timeline
-- scope: shared
--
-- {len(rows)} member_timeline rows, inserted in {len(chunks)} chunks so no single
-- statement carries a multi-megabyte jsonb literal.
--
-- This is the student history GenAlpha's app shows on each child's page.
-- Losing it would not break anything mechanical, which is exactly why it
-- is worth asserting on.
-- ============================================================

{body}

do $$
declare n int;
begin
  select count(*) into n from member_timeline where tenant_id='{T}';
  if n <> {len(rows)} then raise exception 'expected {len(rows)} timeline rows, got %', n; end if;
  if exists (select 1 from member_timeline t where t.tenant_id='{T}'
               and not exists (select 1 from members m where m.id=t.member_id and m.tenant_id='{T}')) then
    raise exception 'a timeline row points outside genalpha';
  end if;
  raise notice 'stage D ok: % timeline rows', n;
end $$;
"""


def main():
    print("  emitting migrations from", SRC)
    write("2026-08-10a-genalpha-schema.sql", stage_a())
    write("2026-08-10b-genalpha-core.sql", stage_b())
    write("2026-08-10c-genalpha-history.sql", stage_c())
    write("2026-08-10d-genalpha-timeline.sql", stage_d())


if __name__ == "__main__":
    main()
