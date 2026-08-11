-- ============================================================
-- 2026-08-11zy · Put the player's name on public.reminder_events
-- scope: shared
--
-- Opening the table editor on reminder_events and seeing a payment
-- confirmation you cannot attribute to a child is not a workaround
-- problem. It is a missing column.
--
-- I answered this three times by pointing at genalpha.reminder_events,
-- which does carry the name. That was the wrong answer: the table people
-- actually open is public.reminder_events, the editor defaults to the
-- public schema, and a row that references a person only by member_id is
-- unreadable by a human at exactly the moment they need to read it.
--
-- The platform already made this decision once and made it the other way.
-- record_fee_payment() writes public.payments.name on every payment,
-- denormalised from members, for precisely this reason. reminder_events
-- simply never got the same treatment.
--
-- So: same column, same purpose, filled by a trigger rather than by each
-- writer. A trigger means no engine has to remember — GenAlpha's, the
-- platform's, and anything written by hand in the SQL editor all get it,
-- and it cannot drift out of step with members.name.
--
-- This is a shared table and the column benefits every tenant: raj's 9
-- reminder rows are just as unreadable without it.
-- ============================================================

alter table public.reminder_events add column if not exists name text;

comment on column public.reminder_events.name is
  'The member''s name at the time of the reminder, denormalised the same way payments.name is. Maintained by the reminder_events_set_name trigger, so no writer has to remember it.';

create or replace function public.reminder_events_set_name()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Only look it up when it is missing or the member changed, so a bulk
  -- update of 568 rows does not do 568 pointless lookups.
  if new.name is null or new.name = ''
     or tg_op = 'INSERT'
     or new.member_id is distinct from old.member_id then
    select m.name into new.name from members m where m.id = new.member_id;
  end if;
  return new;
end $$;

drop trigger if exists reminder_events_set_name on public.reminder_events;
create trigger reminder_events_set_name
  before insert or update on public.reminder_events
  for each row execute function public.reminder_events_set_name();

revoke execute on function public.reminder_events_set_name() from public, anon;

-- Backfill everything that predates the trigger.
update public.reminder_events r
   set name = m.name
  from members m
 where m.id = r.member_id and (r.name is null or r.name = '');

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n int; total int; v text;
begin
  select count(*), count(name) into total, n from reminder_events;
  if n <> total then
    raise exception '% of % reminder rows still have no name', total - n, total;
  end if;
  raise notice 'all % reminder rows carry a player name', total;

  -- every tenant, not just genalpha
  select count(*) into n from reminder_events where tenant_id='raj' and coalesce(name,'')='';
  if n <> 0 then raise exception 'raj has % unnamed reminder rows', n; end if;

  -- THE TRIGGER, exercised. A backfill that works once and a trigger that
  -- never fires would look identical today and diverge tomorrow.
  insert into reminder_events
    (tenant_id, member_id, reminder_type, stage, channel, status,
     overdue_days, retry_count, sent_by, dry_run, ist_date, created_at, updated_at)
  select 'genalpha', m.id, 'renewal', 'due', 'whatsapp', 'dry_run',
         0, 0, 'zy-probe', true, ist_today(), now(), now()
    from members m where m.tenant_id='genalpha' limit 1;

  select name into v from reminder_events where sent_by = 'zy-probe';
  if coalesce(v,'') = '' then
    raise exception 'the trigger did not populate the name on insert';
  end if;
  raise notice 'trigger verified: a new row named "%" without being told', v;

  delete from reminder_events where sent_by = 'zy-probe';
  select count(*) into n from reminder_events;
  if n <> total then raise exception 'the probe left % rows behind', n - total; end if;
end $$;
