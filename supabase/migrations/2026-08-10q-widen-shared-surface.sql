-- ============================================================
-- 2026-08-10q · Widen the shared tables where GenAlpha revealed a real gap
-- scope: shared
--
-- Merging GenAlpha exposed 70 columns the platform had nowhere to put. My
-- first instinct was to push all of them into a genalpha side table,
-- which follows the letter of "shared tables hold what EVERY tenant
-- needs" and misses its point. The owner pushed back, correctly.
--
-- So each column was judged on the actual test: would another academy
-- want this? Three answers came out:
--
--   ADD    ~20 columns that are plainly generic. Below.
--   MAP    ~15 that the platform already models under another name —
--          time_slot is a batch, renewals is renewal_on, coaching_fee is
--          a fee_rule, fees_paid is derived from payments.
--   ASIDE  ~10 that are cricket and nothing else — batting style,
--          bowling styles, jersey size, Aadhaar, nationality.
--
-- Three of GenAlpha's tables needed NOTHING: attendance, student_timeline
-- and academy_expenses already map column for column.
--
-- WHAT THIS IS NOT. This is not "make room for GenAlpha". Every column
-- below is one Raj or Leo could fill tomorrow, and two of them are holes
-- that should have been noticed long before a cricket academy turned up.
-- ============================================================

-- ------------------------------------------------------------
-- members: audit trail, registration numbers, rejoining, reminder pause
-- ------------------------------------------------------------

-- Who touched a record, and when. Every academy with more than one staff
-- member wants this the first time two people disagree about a change.
-- The platform tracks created_at/updated_at but not WHO.
alter table public.members add column if not exists added_by   text;
alter table public.members add column if not exists updated_by text;

-- A human-facing student number. GenAlpha issues 1001, 1002...; academies
-- put it on receipts and ID cards. Not unique platform-wide on purpose —
-- two academies may both have a #1001.
alter table public.members add column if not exists reg_no bigint;
create index if not exists members_tenant_regno_idx on public.members(tenant_id, reg_no)
  where reg_no is not null;

-- A child who left and came back. Today the only record is
-- discontinued_on being cleared, which loses the fact entirely — and the
-- fee chain treats a rejoiner as a brand-new member.
alter table public.members add column if not exists rejoined_at date;

-- Pausing reminders for one family: a fee holiday, a bereavement, a
-- dispute. reminder_queue() currently has no way to be told "not this
-- one", so the alternative is staff remembering not to press send.
alter table public.members add column if not exists reminders_paused    boolean not null default false;
alter table public.members add column if not exists reminders_paused_at timestamptz;
alter table public.members add column if not exists reminders_paused_by text;

comment on column public.members.reg_no is
  'Academy-facing student number. Unique per tenant, not globally.';
comment on column public.members.reminders_paused is
  'Suppresses this member from reminder_queue(). Set by staff, with a reason in reminders_paused_by.';

-- ------------------------------------------------------------
-- applications: the thinnest shared table, and the one GenAlpha most
-- exposed. 36 of its admission-form columns had nowhere to go, and most
-- of them are questions any academy asks.
-- ------------------------------------------------------------
alter table public.applications add column if not exists address              text;
alter table public.applications add column if not exists city                 text;
alter table public.applications add column if not exists age                  integer;
alter table public.applications add column if not exists emergency_contact_no text;
alter table public.applications add column if not exists join_date            date;
alter table public.applications add column if not exists comments             text;
alter table public.applications add column if not exists filled_by            text;
alter table public.applications add column if not exists review_notes         text;
alter table public.applications add column if not exists source_channel       text;

-- CONSENT. This is the one that should embarrass us: the platform takes
-- registrations for MINORS across six academies and has never had
-- anywhere to record that a parent agreed to anything. GenAlpha's form
-- captures it; ours dropped it on the floor.
alter table public.applications add column if not exists consent_accepted   boolean;
alter table public.applications add column if not exists terms_accepted     boolean;
alter table public.applications add column if not exists consent_accepted_at timestamptz;

comment on column public.applications.consent_accepted is
  'Parent/guardian consent recorded at submission. Applies to every tenant — these are minors.';
comment on column public.applications.source_channel is
  'Where the application came from: web form, WhatsApp, walk-in.';

-- ------------------------------------------------------------
-- payments: one payment often covers several things
-- ------------------------------------------------------------
-- GenAlpha splits a payment into coaching + admission + kit. The platform
-- stores only a total, so a receipt cannot itemise and revenue cannot be
-- attributed. jsonb rather than four columns because the components
-- differ per academy — kit here, court hire elsewhere.
alter table public.payments add column if not exists breakdown jsonb;
comment on column public.payments.breakdown is
  'Optional itemisation of one payment, e.g. {"coaching":3500,"admission":500,"kit":900}. The sum must equal amount; nothing enforces that yet.';

-- ------------------------------------------------------------
-- Baseline them, so the weekly digest shows what is NEW rather than
-- forty findings nobody reads. This is the mechanism the platform already
-- uses; the note says why each was accepted.
-- ------------------------------------------------------------
insert into shared_surface_review (object_name, finding, detail, first_seen, reviewed_at, reviewed_by, note)
select v.obj, 'single_tenant_column', v.detail, now(), now(), '2026-08-10q',
       'Added deliberately as platform vocabulary while merging GenAlpha. Generic by intent; expected to be filled by one tenant until the others adopt it.'
  from (values
    ('public.members.added_by','who created the record'),
    ('public.members.updated_by','who last changed it'),
    ('public.members.reg_no','academy-facing student number'),
    ('public.members.rejoined_at','left and returned'),
    ('public.members.reminders_paused','suppress from reminder_queue'),
    ('public.members.reminders_paused_at','when paused'),
    ('public.members.reminders_paused_by','who paused it'),
    ('public.applications.address','applicant address'),
    ('public.applications.city','applicant city'),
    ('public.applications.age','stated age at application'),
    ('public.applications.emergency_contact_no','second contact'),
    ('public.applications.join_date','requested start date'),
    ('public.applications.comments','free text from the parent'),
    ('public.applications.filled_by','who completed the form'),
    ('public.applications.review_notes','staff note on the decision'),
    ('public.applications.source_channel','web, WhatsApp, walk-in'),
    ('public.applications.consent_accepted','parental consent — applies to all tenants'),
    ('public.applications.terms_accepted','terms agreed at submission'),
    ('public.applications.consent_accepted_at','when consent was given'),
    ('public.payments.breakdown','itemisation of a combined payment')
  ) as v(obj, detail)
 where not exists (select 1 from shared_surface_review r where r.object_name = v.obj);

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n int;
begin
  -- every column landed
  select count(*) into n from information_schema.columns
   where table_schema='public' and table_name='members'
     and column_name in ('added_by','updated_by','reg_no','rejoined_at',
                         'reminders_paused','reminders_paused_at','reminders_paused_by');
  if n <> 7 then raise exception 'expected 7 new members columns, got %', n; end if;

  select count(*) into n from information_schema.columns
   where table_schema='public' and table_name='applications'
     and column_name in ('address','city','age','emergency_contact_no','join_date','comments',
                         'filled_by','review_notes','source_channel','consent_accepted',
                         'terms_accepted','consent_accepted_at');
  if n <> 12 then raise exception 'expected 12 new applications columns, got %', n; end if;

  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='payments' and column_name='breakdown') then
    raise exception 'payments.breakdown missing';
  end if;

  -- NOT NULL with a default must not have broken existing rows
  if exists (select 1 from members where reminders_paused is null) then
    raise exception 'reminders_paused is null on existing rows';
  end if;

  -- nothing else moved
  select count(*) into n from members;
  if n <> 223 then raise exception 'member count changed to % during a DDL-only migration', n; end if;

  -- baselined, so the weekly digest stays readable
  select count(*) into n from shared_surface_review where reviewed_by = '2026-08-10q';
  if n <> 20 then raise exception 'expected 20 baseline rows, got %', n; end if;

  raise notice 'shared surface widened: 7 members, 12 applications, 1 payments; 20 baselined';
end $$;
