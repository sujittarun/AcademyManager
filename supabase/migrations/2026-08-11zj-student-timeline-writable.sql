-- ============================================================
-- 2026-08-11zj · The last read-only view GenAlpha's engine writes to
-- scope: shared
--
-- Porting GenAlpha's reminder engine onto the platform needs six
-- relations writable. Five already are: reminder_events and
-- whatsapp_flow_events got INSTEAD OF triggers in 2026-08-11zb,
-- student_payments and students in 2026-08-11ze, and admissions,
-- payment_link_requests and whatsapp_webhook_events are real tables.
--
-- student_timeline is the exception. The engine calls
-- insertStudentTimelineEvent() on every reminder sent, every payment
-- link issued, every parent reply — and that function deliberately
-- swallows its own errors:
--
--     catch (_error) {
--       // Timeline logging must never block the parent or manager
--       // payment flow.
--     }
--
-- So against a read-only view it would fail on every single write and
-- report nothing. The reminders would go out, the payments would land,
-- and the audit trail behind them would be empty — the one outcome worse
-- than a loud failure, because it looks like it worked.
--
-- The trigger writes public.member_timeline, which is where the
-- platform's own record_fee_payment() already writes. One timeline per
-- member, not two.
-- ============================================================

create or replace function genalpha.student_timeline_write()
returns trigger
language plpgsql
security definer
set search_path = genalpha, public
as $$
declare v_member bigint; v_id bigint;
begin
  if tg_op = 'DELETE' then
    delete from member_timeline
     where id = old.id::bigint and tenant_id = 'genalpha';
    return old;
  end if;

  select member_id into v_member
    from genalpha.student_details where legacy_uuid = new.student_id;
  if v_member is null then
    raise exception 'No GenAlpha player with id %', new.student_id;
  end if;

  if tg_op = 'INSERT' then
    -- event_date and changed_by have no column on member_timeline; the
    -- view already reads them back out of meta, so that is where they go.
    insert into member_timeline (tenant_id, member_id, kind, title, body, meta, at)
    values ('genalpha', v_member,
            coalesce(nullif(new.event_type, ''), 'note'),
            coalesce(nullif(new.title, ''), 'Event'),
            new.details,
            jsonb_strip_nulls(jsonb_build_object(
              'event_date', new.event_date,
              'changed_by', nullif(new.changed_by, ''))),
            coalesce(new.created_at, now()))
    returning id into v_id;
    new.id := v_id::text;
    return new;
  end if;

  update member_timeline
     set kind  = coalesce(nullif(new.event_type,''), kind),
         title = coalesce(nullif(new.title,''), title),
         body  = coalesce(new.details, body),
         meta  = jsonb_strip_nulls(coalesce(meta,'{}'::jsonb) || jsonb_build_object(
                   'event_date', new.event_date,
                   'changed_by', nullif(new.changed_by,'')))
   where id = old.id::bigint and tenant_id = 'genalpha';
  return new;
end $$;

create trigger student_timeline_iud instead of insert or update or delete
  on genalpha.student_timeline for each row execute function genalpha.student_timeline_write();

revoke all on genalpha.student_timeline from public, anon;
grant select, insert, update, delete on genalpha.student_timeline to authenticated, service_role;
revoke execute on function genalpha.student_timeline_write() from public, anon;

comment on view genalpha.student_timeline is
  'GenAlpha''s event shape over public.member_timeline. Writable through an INSTEAD OF trigger since 2026-08-11zj; the platform writes the same table from record_fee_payment().';

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare v_student uuid; v_id text; n0 int; n int;
begin
  select count(*) into n0 from genalpha.student_timeline;
  select legacy_uuid into v_student from genalpha.student_details limit 1;

  -- Exactly the payload the engine sends: student_id, event_type,
  -- event_date, title, details, changed_by.
  insert into genalpha.student_timeline
    (student_id, event_type, event_date, title, details, changed_by)
  values (v_student, 'reminder_sent', current_date, 'Probe',
          'migration probe', 'zj@example.invalid')
  returning id into v_id;

  if v_id is null then raise exception 'the timeline insert returned no id'; end if;

  -- It must land on member_timeline, not somewhere GenAlpha-only.
  if not exists (select 1 from member_timeline
                  where id = v_id::bigint and tenant_id='genalpha' and kind='reminder_sent') then
    raise exception 'the insert did not reach member_timeline';
  end if;

  -- and read back through the view with every field intact, including
  -- the two that live in meta
  if not exists (select 1 from genalpha.student_timeline
                  where id = v_id and event_type='reminder_sent'
                    and changed_by='zj@example.invalid'
                    and event_date = current_date
                    and details = 'migration probe') then
    raise exception 'the row does not read back with event_date and changed_by intact';
  end if;

  delete from genalpha.student_timeline where id = v_id;
  select count(*) into n from genalpha.student_timeline;
  if n <> n0 then raise exception 'the probe left % rows behind', n - n0; end if;

  -- Every relation the engine writes is now writable. Asserted here
  -- rather than discovered at 2am by a function that swallows its errors.
  select count(*) into n from (
    select unnest(array['students','student_payments','reminder_events',
                        'whatsapp_flow_events','student_timeline','academy_expenses']) v) x
   where not exists (
     select 1 from pg_trigger t
      where t.tgrelid = ('genalpha.' || x.v)::regclass and not t.tgisinternal);
  if n <> 0 then raise exception '% genalpha view(s) still have no INSTEAD OF trigger', n; end if;

  raise notice 'student_timeline is writable; all six genalpha views now accept writes';
end $$;
