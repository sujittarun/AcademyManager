-- ============================================================
-- 2026-08-11zf · Two id spaces where there should be one
-- scope: shared
--
-- genalpha.payment_link_requests.reminder_event_id and
-- genalpha.whatsapp_webhook_events.reminder_event_id are `uuid`. Reminder
-- ids are now public.reminder_events.id — bigint, surfaced through the
-- view as text. 2026-08-11kz migrated the reminder history without
-- preserving the legacy uuid, so the two spaces are disjoint and nothing
-- joins.
--
-- Two consequences, both currently masked by bugs fixed earlier today and
-- both surfacing the moment those fixes land:
--
--   READ  script.js:3869 keys link rows by uuid against text-of-bigint
--         reminder ids, so matchedLink is always undefined and
--         normalizePaymentFollowUp drops plan_type, amount,
--         months_covered, cycle_start_date and payment_link_url. A parent
--         who already chose a plan renders with no plan and no amount.
--   WRITE script.js:4869 sends a text-of-bigint into a uuid column:
--         22P02.
--
-- NOT nulled. All 61 distinct uuids referenced by the 172 rows appear in
-- the pre-merge export, and the export's created_at survived the merge to
-- the microsecond — the same join that restored the dropped columns. So
-- every reference is remapped to its real bigint and nothing is thrown
-- away. Coverage is asserted at the end rather than assumed.
-- ============================================================

create temporary table _uu_map (legacy uuid primary key, ts timestamptz) on commit drop;
insert into _uu_map (legacy, ts) values
    ('30b2de4f-9b66-49a1-8846-7e1ebfb08b13'::uuid, '2026-06-16T15:00:01.986376+05:30'::timestamptz),
    ('291abfb1-471e-4284-a5d9-f32560b2d27d'::uuid, '2026-08-09T15:00:02.871569+05:30'::timestamptz),
    ('8e740688-96f5-43a0-9fed-f8c5f5dd486a'::uuid, '2026-07-22T15:00:00.809838+05:30'::timestamptz),
    ('72af078a-2cca-4c82-b393-371124794fcb'::uuid, '2026-05-28T15:00:03.054694+05:30'::timestamptz),
    ('3994a3d5-ec03-4a69-809d-d88b816336c2'::uuid, '2026-06-16T15:00:02.188861+05:30'::timestamptz),
    ('354d84a5-3691-4c85-a157-0c7d7e408c97'::uuid, '2026-07-16T15:00:01.714382+05:30'::timestamptz),
    ('0bdea3e1-3032-4203-9797-c3062e4fa779'::uuid, '2026-07-31T15:00:01.348099+05:30'::timestamptz),
    ('da377553-008e-400b-a1e9-0dd68538de9a'::uuid, '2026-06-11T15:00:03.663459+05:30'::timestamptz),
    ('69400a6d-4325-4c90-a8d5-1c8138e50d25'::uuid, '2026-06-08T15:00:02.131827+05:30'::timestamptz),
    ('7e952022-a46c-45d5-a761-685e6fd167a6'::uuid, '2026-05-04T22:57:11.570671+05:30'::timestamptz),
    ('97658b42-29ad-4c68-818f-5bd5dcd7334d'::uuid, '2026-06-23T15:00:01.724335+05:30'::timestamptz),
    ('11b3b308-827b-4768-a0e4-4d6481d91345'::uuid, '2026-06-19T15:00:01.829213+05:30'::timestamptz),
    ('15786ae8-17c7-4cd3-9626-0d31b37190cf'::uuid, '2026-08-09T15:00:00.99304+05:30'::timestamptz),
    ('fd1138ab-83bf-43ea-846e-f5232a49a672'::uuid, '2026-06-11T15:00:02.855195+05:30'::timestamptz),
    ('47986013-a687-4924-b68d-1feffafbfc74'::uuid, '2026-06-16T15:00:01.761769+05:30'::timestamptz),
    ('c86f5014-f320-46db-93a7-c863ad051fde'::uuid, '2026-05-11T15:47:10.590789+05:30'::timestamptz),
    ('85fcba7c-aa57-44c3-b3de-9e4cd5c30454'::uuid, '2026-08-06T15:00:01.383476+05:30'::timestamptz),
    ('66c276ca-dff4-46f6-a51b-05b264399b03'::uuid, '2026-05-20T15:00:02.398397+05:30'::timestamptz),
    ('5cff768b-6899-4eda-aafb-22bd47ad54e9'::uuid, '2026-06-27T15:00:02.624689+05:30'::timestamptz),
    ('ff8a47c6-71f2-46e4-a888-c465e2d4f6bb'::uuid, '2026-06-02T15:00:02.257085+05:30'::timestamptz),
    ('e5fa5619-f187-401a-a5c7-7f9459737f20'::uuid, '2026-07-22T15:00:01.214525+05:30'::timestamptz),
    ('11e7b85f-05b4-4e9a-a87f-286dbef3a451'::uuid, '2026-05-15T15:00:02.131286+05:30'::timestamptz),
    ('15fafca5-44d6-46ae-8936-5a7689754d54'::uuid, '2026-07-01T15:00:02.094466+05:30'::timestamptz),
    ('d5692b1f-2855-41e0-8b78-3b4768732199'::uuid, '2026-05-09T16:53:12.621535+05:30'::timestamptz),
    ('50645288-3750-43aa-95bf-c542dae22a65'::uuid, '2026-05-11T15:46:43.028624+05:30'::timestamptz),
    ('1b34c6f1-bd27-4641-8867-f5cee58c2b80'::uuid, '2026-06-13T15:00:03.537327+05:30'::timestamptz),
    ('0c02c6dd-cb4a-407b-b256-e4bca6ff42e8'::uuid, '2026-08-06T15:00:02.690767+05:30'::timestamptz),
    ('1b7d9563-79aa-4634-958f-274fa9c2bff2'::uuid, '2026-06-06T15:00:02.924671+05:30'::timestamptz),
    ('04dc391f-6bfd-4847-9ea5-f6edf209872b'::uuid, '2026-08-07T15:00:02.216154+05:30'::timestamptz),
    ('62a82595-3704-49e8-834e-118b53d188c3'::uuid, '2026-07-07T15:00:02.844541+05:30'::timestamptz),
    ('b71049d4-1245-481b-9307-19a320f1d4ab'::uuid, '2026-07-31T15:00:01.101106+05:30'::timestamptz),
    ('3366c4ce-2cbf-4ce1-9870-41813f7d1d51'::uuid, '2026-07-20T15:00:01.006066+05:30'::timestamptz),
    ('7cd6dc1d-07a2-46dd-86b3-7101859f2510'::uuid, '2026-07-16T15:00:02.747118+05:30'::timestamptz),
    ('0f54056e-032b-4f36-991a-87ebde610914'::uuid, '2026-06-12T15:00:02.424747+05:30'::timestamptz),
    ('60a61d5a-097f-4102-9082-c6e51989d1de'::uuid, '2026-07-16T15:00:02.950369+05:30'::timestamptz),
    ('21ec1d9e-0b18-45ee-b700-6a817655d1be'::uuid, '2026-06-02T15:00:02.651495+05:30'::timestamptz),
    ('9c6bcba6-e7f4-4e66-b81a-f2f4b0eb346a'::uuid, '2026-05-08T16:31:04.673844+05:30'::timestamptz),
    ('2da92e48-ca41-4037-9804-01bdb21e12ec'::uuid, '2026-07-21T15:00:01.930656+05:30'::timestamptz),
    ('a199338d-9cc2-4dba-8501-507f08f17ddc'::uuid, '2026-07-25T15:00:01.334904+05:30'::timestamptz),
    ('acebb560-888c-4c4c-b88a-0c6fb4cb5e8d'::uuid, '2026-07-05T15:00:02.748939+05:30'::timestamptz),
    ('4848029f-d213-4285-8a67-b4e4b6f7108a'::uuid, '2026-07-06T15:00:03.387267+05:30'::timestamptz),
    ('fd906ed8-025d-4a98-926d-959730f0fc9e'::uuid, '2026-07-20T15:00:01.879087+05:30'::timestamptz),
    ('821cc5ab-daa4-4335-a1b8-9b3d73b003a2'::uuid, '2026-07-24T15:00:02.023053+05:30'::timestamptz),
    ('713ab43e-f547-41f4-b2cc-587727669c99'::uuid, '2026-06-30T15:00:02.91751+05:30'::timestamptz),
    ('c27db476-727a-4035-9403-8810b15026f7'::uuid, '2026-07-05T15:00:03.375159+05:30'::timestamptz),
    ('6e0760e6-9849-46cf-8bb5-0efc3704d503'::uuid, '2026-07-28T15:00:01.573662+05:30'::timestamptz),
    ('42c686af-cdf5-45fb-8464-afa6b7278e41'::uuid, '2026-06-21T15:00:01.816687+05:30'::timestamptz),
    ('85073f1d-c796-43c7-98c8-fac22fe4cd7e'::uuid, '2026-07-19T15:00:01.633279+05:30'::timestamptz),
    ('fcbc7658-169a-481b-ae04-82582c794f3e'::uuid, '2026-06-21T15:00:03.078707+05:30'::timestamptz),
    ('d309a5c3-dabf-41bb-b850-5ecd5e99ebcd'::uuid, '2026-07-21T15:00:00.876883+05:30'::timestamptz),
    ('60f0f89a-165d-4f00-96c3-66dc35b10b26'::uuid, '2026-06-22T15:00:02.618253+05:30'::timestamptz),
    ('6ce0a5e7-ac79-4577-80a7-ee925ba753b2'::uuid, '2026-07-28T15:00:01.799654+05:30'::timestamptz),
    ('60d487e5-6eeb-4390-8356-29479f8c5d2c'::uuid, '2026-06-19T15:00:02.027601+05:30'::timestamptz),
    ('8ddd35b7-d98c-405e-8361-22fd300e8866'::uuid, '2026-06-29T15:00:02.261576+05:30'::timestamptz),
    ('23b1bab2-44a7-46a3-9bc9-a22e6542f1de'::uuid, '2026-07-13T15:00:03.165307+05:30'::timestamptz),
    ('af8aefa2-77a7-450a-b612-4f357f465787'::uuid, '2026-05-13T15:00:03.584085+05:30'::timestamptz),
    ('5086dde6-a993-4be7-9519-f6d754ef64f2'::uuid, '2026-06-28T15:00:03.73022+05:30'::timestamptz),
    ('c4a45cf5-6ab9-4a65-b5f9-729d1f0dcbcd'::uuid, '2026-06-11T15:00:04.089367+05:30'::timestamptz),
    ('b93b55a8-e8bd-4a1a-95a2-d33c744f7fa3'::uuid, '2026-06-06T15:00:03.328531+05:30'::timestamptz),
    ('d2427ab5-422d-47e9-ae22-08065cf52bfe'::uuid, '2026-07-06T15:00:02.372189+05:30'::timestamptz),
    ('831d374e-8e22-4f15-b924-b6d5fc340c26'::uuid, '2026-05-15T15:00:01.936646+05:30'::timestamptz);

create temporary table _uu_resolved on commit drop as
select m.legacy, r.id as new_id
  from _uu_map m
  join public.reminder_events r on r.tenant_id = 'genalpha' and r.created_at = m.ts;

do $$
declare n int; total int;
begin
  select count(*) into n from _uu_resolved;
  select count(*) into total from _uu_map;
  if n <> total then
    raise exception 'only % of % legacy reminder uuids resolved to a bigint', n, total;
  end if;
  -- and no two legacy uuids collapsed onto the same reminder
  select count(*) into n from (select new_id from _uu_resolved group by 1 having count(*) > 1) z;
  if n > 0 then raise exception '% reminders are claimed by more than one legacy uuid', n; end if;
end $$;

-- ------------------------------------------------------------
-- payment_link_requests
-- ------------------------------------------------------------
alter table genalpha.payment_link_requests add column if not exists reminder_event_new bigint;
update genalpha.payment_link_requests p
   set reminder_event_new = r.new_id
  from _uu_resolved r
 where r.legacy = p.reminder_event_id;

do $$
declare n int;
begin
  select count(*) into n from genalpha.payment_link_requests
   where reminder_event_id is not null and reminder_event_new is null;
  if n > 0 then raise exception '% payment link rows lost their reminder', n; end if;
end $$;

alter table genalpha.payment_link_requests drop column reminder_event_id;
alter table genalpha.payment_link_requests rename column reminder_event_new to reminder_event_id;
alter table genalpha.payment_link_requests
  add constraint payment_link_requests_reminder_fk
  foreign key (reminder_event_id) references public.reminder_events(id) on delete set null;

-- ------------------------------------------------------------
-- whatsapp_webhook_events
-- ------------------------------------------------------------
alter table genalpha.whatsapp_webhook_events add column if not exists reminder_event_new bigint;
update genalpha.whatsapp_webhook_events w
   set reminder_event_new = r.new_id
  from _uu_resolved r
 where r.legacy = w.reminder_event_id;

do $$
declare n int;
begin
  select count(*) into n from genalpha.whatsapp_webhook_events
   where reminder_event_id is not null and reminder_event_new is null;
  if n > 0 then raise exception '% webhook rows lost their reminder', n; end if;
end $$;

alter table genalpha.whatsapp_webhook_events drop column reminder_event_id;
alter table genalpha.whatsapp_webhook_events rename column reminder_event_new to reminder_event_id;
alter table genalpha.whatsapp_webhook_events
  add constraint whatsapp_webhook_events_reminder_fk
  foreign key (reminder_event_id) references public.reminder_events(id) on delete set null;

comment on column genalpha.payment_link_requests.reminder_event_id is
  'public.reminder_events.id. Was a pre-merge uuid until 2026-08-11zf; remapped, not discarded.';

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n int;
begin
  -- both columns are bigint now
  if (select data_type from information_schema.columns
       where table_schema='genalpha' and table_name='payment_link_requests'
         and column_name='reminder_event_id') <> 'bigint' then
    raise exception 'payment_link_requests.reminder_event_id is still not bigint';
  end if;

  -- every reference survived, and points at a real genalpha reminder
  select count(*) into n from genalpha.payment_link_requests where reminder_event_id is not null;
  if n <> 76 then raise exception 'payment links now reference % reminders, expected 76', n; end if;
  select count(*) into n from genalpha.whatsapp_webhook_events where reminder_event_id is not null;
  if n <> 96 then raise exception 'webhook rows now reference % reminders, expected 96', n; end if;

  select count(*) into n from genalpha.payment_link_requests p
    join public.reminder_events r on r.id = p.reminder_event_id
   where r.tenant_id <> 'genalpha';
  if n <> 0 then raise exception '% payment links point at another tenant''s reminder', n; end if;

  -- THE JOIN THE APP DOES. script.js:3869 builds linksByReminder keyed on
  -- the reminder id; before this it matched nothing at all.
  select count(*) into n
    from genalpha.reminder_events g
    join genalpha.payment_link_requests p on p.reminder_event_id = g.id::bigint;
  if n = 0 then raise exception 'the reminder-to-payment-link join still matches nothing'; end if;
  raise notice '% reminders now resolve to a payment link', n;
end $$;
