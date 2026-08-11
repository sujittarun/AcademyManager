-- ============================================================
-- 2026-08-11zt · reminder_events, with the player's name on it
-- scope: shared
--
-- The daily tracking query was coming back short. Two different things,
-- and only one of them was missing data.
--
-- WHAT WAS NOT MISSING. genalpha.reminder_events already carries all 50
-- columns — message_preview, selected_plan, payment_link_url,
-- delivered_at, read_at, payment_link_sent_at, payment_confirmed_at, the
-- retry chain — and the status values match GenAlpha's own database
-- almost row for row (read 231, failed 91, payment_confirmed 76,
-- delivered 76, payment_link_sent 21, and so on).
--
-- What the SQL editor shows by default is public.reminder_events: the
-- PLATFORM's 27-column table, which is the storage underneath, not
-- GenAlpha's view of it. The editor's search_path is `public`, so an
-- unqualified `select * from reminder_events` lands there.
--
--   Track this instead:  select * from genalpha.reminder_events
--
-- WHAT WAS GENUINELY MISSING. The player's name. GenAlpha's own table did
-- not have it either — it keys on student_id, a uuid — so tracking meant
-- joining to students every time. Added here, because the whole point of
-- this relation is being read by a person at a glance.
-- ============================================================

drop view if exists genalpha.reminder_events cascade;
create view genalpha.reminder_events with (security_invoker = true) as
 SELECT r.id::text AS id,
    d.legacy_uuid AS student_id,
    r.reminder_type,
    r.channel,
    r.status,
    r.dry_run,
    r.due_date,
    r.overdue_days,
    x.plan_options,
    x.selected_plan,
    r.amount,
    x.payment_link_url,
    x.payment_link_id,
    r.to_phone AS parent_phone,
    x.manager_phone,
    x.message_preview,
    x.help_requested,
    x.created_by,
    r.created_at,
    x.whatsapp_message_id,
    x.meta_response,
    x.meta_error,
    x.accepted_at,
    x.delivered_at,
    x.read_at,
    x.failed_at,
    x.payment_link_sent_at,
    x.payment_attempted_at,
    x.payment_pending_verification_at,
    x.payment_confirmed_at,
    x.confirmation_message_id,
    x.confirmation_sent_at,
    x.confirmation_delivered_at,
    x.confirmation_read_at,
    x.confirmation_failed_at,
    x.confirmation_meta_response,
    x.confirmation_meta_error,
    r.retry_count,
    x.max_retry_count,
    r.next_retry_at,
    x.last_retry_at,
    x.retry_reason,
    x.manual_followup_required,
    x.manager_payment_alert_status,
    x.manager_payment_alert_due_at,
    x.manager_payment_alert_sent_at,
    x.manager_payment_alert_meta_response,
    NULL::text AS manager_payment_alert_error,
    x.manual_followup_reason,
    r.stage,
    m.name AS student_name,
    m.reg_no
   FROM reminder_events r
     LEFT JOIN genalpha.reminder_event_details x ON x.reminder_event_id = r.id
     LEFT JOIN genalpha.student_details d ON d.member_id = r.member_id
     LEFT JOIN members m ON m.id = r.member_id
  WHERE r.tenant_id = 'genalpha'::text;

revoke all on genalpha.reminder_events from public, anon;
grant select, insert, update, delete on genalpha.reminder_events to authenticated, service_role;

create trigger reminder_events_iud instead of insert or update or delete
  on genalpha.reminder_events for each row execute function genalpha.reminder_events_write();

comment on view genalpha.reminder_events is
  'GenAlpha''s 50-column reminder shape plus student_name and reg_no. This is the one to track daily; public.reminder_events is the platform storage underneath it.';

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n int;
begin
  select count(*) into n from information_schema.columns
   where table_schema='genalpha' and table_name='reminder_events';
  if n <> 52 then raise exception 'view has % columns, expected 52 (50 + name + reg_no)', n; end if;

  -- the columns the daily query needs, by name
  select count(*) into n from information_schema.columns
   where table_schema='genalpha' and table_name='reminder_events'
     and column_name in ('student_name','reg_no','message_preview','selected_plan',
                         'payment_link_url','delivered_at','read_at','payment_link_sent_at',
                         'payment_confirmed_at','status','reminder_type');
  if n <> 11 then raise exception 'only % of the 11 tracking columns are exposed', n; end if;

  -- names must actually resolve, not sit null
  select count(*) into n from genalpha.reminder_events where coalesce(student_name,'') = '';
  if n > 0 then raise exception '% reminder rows have no player name', n; end if;

  -- row count unchanged: a left join that fans out would inflate it
  select count(*) into n from genalpha.reminder_events;
  if n <> 581 then raise exception 'view returns % rows, expected 581', n; end if;

  -- and the trigger is back after the drop/recreate, or writes stop dead
  if not exists (select 1 from pg_trigger
                  where tgrelid='genalpha.reminder_events'::regclass and not tgisinternal) then
    raise exception 'the INSTEAD OF trigger did not survive the rebuild';
  end if;

  raise notice 'genalpha.reminder_events now carries the player name; % rows', n;
end $$;
