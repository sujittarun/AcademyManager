-- ============================================================
-- 2026-08-11za · Three columns ended up in both places, disagreeing
-- scope: shared
--
-- 2026-08-11z1 created the side tables from "columns the merge did not
-- carry". Three of them — reminder_type, dry_run, retry_count — DO exist
-- on the shared reminder_events. They were on the list because the merge
-- wrote them without reading GenAlpha's values, so the shared copy was
-- populated but wrong, and the real values only existed in the archive.
--
-- Comparing the two copies across all 568 rows:
--
--   reminder_type   223 rows differ. The shared table says 'renewal' for
--                   every row. GenAlpha has four values: heads_up,
--                   renewal_day, renewal, joining_fee.
--   dry_run         562 of 568 differ — the merge wrote a default.
--   retry_count     8 differ.
--
-- The shared copy is the fabricated one. And reminder_type is not
-- GenAlpha trivia: heads_up / renewal_day / renewal is the platform's own
-- ladder, the one PLATFORM.md describes as "-2 heads-up, 0 due, +5 first
-- chase". Flattening it to 'renewal' erased which rung each of 568
-- reminders was on, which is the single most useful thing about a
-- reminder record.
--
-- So the values go UP into the shared table, where they belong, and come
-- OUT of the side table, so there is one copy. The side table keeps only
-- what the platform genuinely has nowhere to put.
--
-- Raj's 9 rows are untouched; they are all 'renewal' and always were.
-- ============================================================

update reminder_events r
   set reminder_type = coalesce(nullif(d.reminder_type, ''), r.reminder_type),
       dry_run       = coalesce(d.dry_run, r.dry_run),
       retry_count   = coalesce(d.retry_count, r.retry_count)
  from genalpha.reminder_event_details d
 where d.reminder_event_id = r.id
   and r.tenant_id = 'genalpha';

alter table genalpha.reminder_event_details drop column reminder_type;
alter table genalpha.reminder_event_details drop column dry_run;
alter table genalpha.reminder_event_details drop column retry_count;

comment on column public.reminder_events.reminder_type is
  'Which rung of the ladder this reminder is: heads_up (-2), renewal_day (0), renewal (chase), joining_fee. Populated for genalpha in 2026-08-11za after the merge flattened all 568 rows to ''renewal''.';

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n int; v text;
begin
  -- The four values are back on the shared row.
  select string_agg(distinct reminder_type, ',' order by reminder_type) into v
    from reminder_events where tenant_id = 'genalpha';
  if v is distinct from 'heads_up,joining_fee,renewal,renewal_day' then
    raise exception 'genalpha reminder types are now %, expected four', v;
  end if;

  -- Assert on the SPREAD, not just the set. One row of each would satisfy
  -- the check above while 564 rows stayed flattened.
  select count(*) into n from reminder_events
   where tenant_id='genalpha' and reminder_type <> 'renewal';
  if n < 200 then
    raise exception 'only % rows carry a non-renewal type; 223 differed before the lift', n;
  end if;
  raise notice '% of 568 genalpha reminders are something other than a plain chase', n;

  -- The duplication is gone.
  select count(*) into n from information_schema.columns
   where table_schema='genalpha' and table_name='reminder_event_details'
     and column_name in ('reminder_type','dry_run','retry_count');
  if n <> 0 then raise exception '% duplicated column(s) remain in the side table', n; end if;

  -- Nothing was lost in the drop: the side table still has the rest.
  select count(*) into n from information_schema.columns
   where table_schema='genalpha' and table_name='reminder_event_details';
  if n <> 36 then raise exception 'side table has % columns, expected 36 (1 key + 35)', n; end if;

  select count(*) into n from genalpha.reminder_event_details;
  if n <> 568 then raise exception 'side table lost rows: %', n; end if;

  -- Raj must be exactly as it was.
  select count(*) into n from reminder_events where tenant_id='raj' and reminder_type <> 'renewal';
  if n <> 0 then raise exception 'raj''s reminder types changed'; end if;
  select count(*) into n from reminder_events where tenant_id='raj';
  if n <> 9 then raise exception 'raj now has % reminder rows, expected 9', n; end if;

  raise notice 'reminder_type, dry_run and retry_count lifted to the shared row; one copy each';
end $$;
