-- Demo tenant: every phone becomes the owner's, and the academy is renamed.
--
-- WHY A TRIGGER AND NOT AN UPDATE
--
-- The obvious change is `update members set phone = ... where tenant_id =
-- 'demo'`. It would work today and revert the next time anyone runs
-- demo_reset('rebuild') — which the demo repo documents as the thing you
-- run "after a demo has been clicked through", so it runs often. The
-- rebuild branch re-inserts all 94 members with sequential synthetic
-- phones from 9000000201.
--
-- Editing demo_reset's body instead would mean replacing ~300 lines of
-- seed logic to change two expressions. A tenant-guarded trigger pins the
-- value at write time, so it survives rebuild, the nightly roll, and any
-- future hand-inserted row, in ten lines.
--
-- The trigger fires on shared `members`, so it fires for all six tenants.
-- The guard is what makes that safe, and this file is shared-scope
-- precisely because a trigger on a shared table is never tenant-repo
-- material — that is the player-progress-matchpoint lesson.
--
-- WHY THE OWNER'S OWN NUMBER
--
-- The demo is about to be linked publicly. Pointing every row at the
-- owner's number means (a) no real person can ever be contacted from the
-- demo, and (b) if a prospect taps a member's WhatsApp link, the owner
-- gets the message and learns someone is exploring. The seed's own
-- comment anticipated the first half: "the client rebrand must also
-- remove the outbound wa.me links, which bypass the send path." We are
-- keeping those links on purpose — they are now a buying signal, and they
-- can only reach the owner.
--
-- Scope: shared. Demo tenant only, enforced in the trigger body.
--
-- No begin/commit: migrate.sh wraps this in one transaction.

-- ─────────────────────────────────────────────────────────────
-- 1. The owner's number, in one place
-- ─────────────────────────────────────────────────────────────
create or replace function public.demo_owner_phone()
returns text language sql immutable as $$ select '9951597567' $$;

comment on function public.demo_owner_phone() is
  'The number every demo-tenant contact resolves to. One definition, so '
  'the trigger, the seed and any backfill cannot disagree.';

-- ─────────────────────────────────────────────────────────────
-- 2. Pin demo contact numbers at write time
-- ─────────────────────────────────────────────────────────────
create or replace function public.demo_pin_contact_phones()
returns trigger language plpgsql
set search_path = public as $$
begin
  -- Tenant-guarded FIRST. This trigger is on a shared table and fires for
  -- every academy; without this line it would overwrite real families'
  -- phone numbers with the demo owner's.
  if new.tenant_id is distinct from 'demo' then
    return new;
  end if;
  new.phone        := demo_owner_phone();
  new.parent_phone := demo_owner_phone();
  return new;
end $$;

comment on function public.demo_pin_contact_phones() is
  'Forces demo-tenant member and parent phones to demo_owner_phone(). '
  'Tenant-guarded on the first line: it runs on shared members.';

drop trigger if exists demo_pin_phones on public.members;
create trigger demo_pin_phones
  before insert or update of phone, parent_phone on public.members
  for each row execute function public.demo_pin_contact_phones();

-- ─────────────────────────────────────────────────────────────
-- 3. Backfill the rows that already exist
-- ─────────────────────────────────────────────────────────────
update public.members
   set phone = demo_owner_phone()
 where tenant_id = 'demo'
   and coalesce(phone, '') <> demo_owner_phone();

update public.members
   set parent_phone = demo_owner_phone()
 where tenant_id = 'demo'
   and coalesce(parent_phone, '') <> demo_owner_phone();

-- Coaches carry phones too, and a prospect clicking a coach is the same
-- signal. Same tenant filter — ids are global, so an unfiltered UPDATE
-- here would rewrite every academy's staff numbers.
update public.coaches
   set phone = demo_owner_phone()
 where tenant_id = 'demo'
   and coalesce(phone, '') <> demo_owner_phone();

-- ─────────────────────────────────────────────────────────────
-- 4. Rename the academy. The operator console reads tenants.name via
--    operator_portfolio(), so this renames it in Academy Manager too —
--    there is no second place to edit.
-- ─────────────────────────────────────────────────────────────
update public.tenants
   set name = 'Sports Academy'
 where id = 'demo';

-- Centres were seeded "Crescent Central" / "Crescent North", and
-- demo_reset('rebuild') re-inserts them — so the rename needs the same
-- trigger treatment as the phones, for the same reason. The behaviour test
-- caught this by running a rebuild and finding "Crescent" back.
create or replace function public.demo_pin_centre_name()
returns trigger language plpgsql
set search_path = public as $$
begin
  -- tenant-guarded first: this runs on shared centres
  if new.tenant_id is distinct from 'demo' then
    return new;
  end if;
  new.name := btrim(replace(new.name, 'Crescent', ''));
  return new;
end $$;

comment on function public.demo_pin_centre_name() is
  'Strips the retired "Crescent" brand from demo centre names at write '
  'time, so demo_reset(rebuild) cannot restore it. Tenant-guarded.';

drop trigger if exists demo_pin_centre on public.centres;
create trigger demo_pin_centre
  before insert or update of name on public.centres
  for each row execute function public.demo_pin_centre_name();

update public.centres
   set name = btrim(replace(name, 'Crescent', ''))
 where tenant_id = 'demo'
   and name like '%Crescent%';

-- ─────────────────────────────────────────────────────────────
-- 5. Prove it, in the migration, so a replay re-checks it
-- ─────────────────────────────────────────────────────────────
do $$
declare n int; v_name text;
begin
  select count(*) into n from members
   where tenant_id = 'demo'
     and (coalesce(phone,'') <> demo_owner_phone()
       or coalesce(parent_phone,'') <> demo_owner_phone());
  if n > 0 then
    raise exception '% demo member(s) still carry a non-owner phone', n;
  end if;

  -- and the guard must hold: no OTHER tenant may have been touched
  select count(*) into n from members
   where tenant_id <> 'demo' and phone = demo_owner_phone();
  if n > 0 then
    raise exception
      'the owner phone appears on % row(s) OUTSIDE the demo tenant — the '
      'trigger guard or an UPDATE was unfiltered', n;
  end if;

  select name into v_name from tenants where id = 'demo';
  if v_name <> 'Sports Academy' then
    raise exception 'demo tenant name is %, expected Sports Academy', v_name;
  end if;

  if exists (select 1 from centres where tenant_id = 'demo'
              and name like 'Crescent%') then
    raise exception 'a demo centre is still named Crescent...';
  end if;

  -- the triggers must actually be attached, or the next rebuild reverts
  if not exists (select 1 from pg_trigger
                  where tgname = 'demo_pin_phones' and not tgisinternal) then
    raise exception 'demo_pin_phones trigger is not attached';
  end if;
  if not exists (select 1 from pg_trigger
                  where tgname = 'demo_pin_centre' and not tgisinternal) then
    raise exception 'demo_pin_centre trigger is not attached';
  end if;

  raise notice 'demo: phones pinned to owner, renamed Sports Academy, no other tenant touched';
end $$;

revoke execute on function public.demo_owner_phone() from public, anon;
revoke execute on function public.demo_pin_contact_phones() from public, anon;
revoke execute on function public.demo_pin_centre_name() from public, anon;
