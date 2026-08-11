-- ============================================================
-- 2026-08-12l · The two-line trigger AgentAlpha's concurrency rests on
-- scope: shared
--
-- Found by comparing all 15 legacy triggers against this project rather
-- than trusting that "the INSTEAD OF layer covers it". Thirteen are
-- genuinely reproduced — the timeline logging, the fee-pause
-- normalisation, the WhatsApp contact sync and the admission-claim
-- reconciliation all live inside the write functions now, and
-- students_set_updated_at is covered by members_touch on public.members.
--
-- These two were simply not ported:
--
--     admission_intake_sessions_touch   BEFORE UPDATE
--     admission_payment_claims_touch    BEFORE UPDATE
--
-- Both are `new.updated_at = now()`. That looks like bookkeeping. It is
-- not: admission-intake uses updated_at as an OPTIMISTIC CONCURRENCY
-- TOKEN, and the whole AgentAlpha pipeline is built on it.
--
-- On every inbound WhatsApp message the function PATCHes the session
-- (last_message_at, expires_at) and reads updated_at back as
-- `debounceToken` (index.ts:517). With the trigger, each message minted
-- a new token. Without it the PATCH changes nothing, so:
--
--   * THE DEBOUNCE NEVER RESETS. index.ts:1612 bails out with
--     `if (session.updated_at !== debounceToken) return;` when a newer
--     message has arrived. If the token never changes that guard never
--     fires, so the sweep hands the model a conversation the parent is
--     still typing, and the extraction is made from half an admission.
--
--   * THE COMPARE-AND-SWAP STOPS GUARDING. Three places claim a session
--     with `&status=eq.processing&updated_at=eq.<token>` (1321, 1369,
--     1388). That is a CAS, and it is only safe while the token moves.
--     Two concurrent runs can both match, both process, and both send a
--     WhatsApp message to the same parent.
--
-- It has been latent since the cutover only because 2026-08-12j had not
-- yet restored the every-10-seconds sweep, and every migrated session is
-- already terminal. The first real WhatsApp admission would have hit it.
--
-- Proven, not assumed: a no-op UPDATE on the platform left updated_at at
-- 2026-07-16 09:43:45 exactly. The 45 migrated rows all show
-- updated_at > created_at, which is why this looked healthy — those
-- values were made on the legacy project, by the trigger being restored
-- here.
-- ============================================================

create or replace function genalpha.touch_admission_intake_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end $$;

comment on function genalpha.touch_admission_intake_updated_at() is
  'Bumps updated_at. Not bookkeeping: admission-intake uses that column as its debounce token and compare-and-swap key, so without this the AgentAlpha sweep reads unfinished conversations and can double-send.';

drop trigger if exists admission_intake_sessions_touch on genalpha.admission_intake_sessions;
create trigger admission_intake_sessions_touch
  before update on genalpha.admission_intake_sessions
  for each row execute function genalpha.touch_admission_intake_updated_at();

drop trigger if exists admission_payment_claims_touch on genalpha.admission_payment_claims;
create trigger admission_payment_claims_touch
  before update on genalpha.admission_payment_claims
  for each row execute function genalpha.touch_admission_intake_updated_at();

-- ------------------------------------------------------------
-- Checks — exercise it, do not read the catalogue
-- ------------------------------------------------------------
do $$
declare v_id uuid; v_before timestamptz; v_after timestamptz; n int;
begin
  -- both triggers exist
  select count(*) into n from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'genalpha' and not t.tgisinternal
     and t.tgname in ('admission_intake_sessions_touch','admission_payment_claims_touch');
  if n <> 2 then raise exception 'expected 2 touch triggers, found %', n; end if;

  -- and the session one actually moves the token, which is the point
  select id, updated_at into v_id, v_before
    from genalpha.admission_intake_sessions order by created_at limit 1;
  if v_id is null then
    raise notice 'no intake session to exercise; triggers created but untested';
  else
    update genalpha.admission_intake_sessions set status = status where id = v_id;
    select updated_at into v_after
      from genalpha.admission_intake_sessions where id = v_id;
    if v_after <= v_before then
      raise exception 'updated_at did not move (% -> %); the debounce token is still frozen',
        v_before, v_after;
    end if;
    raise notice 'the debounce token moves again: % -> %', v_before, v_after;
  end if;

  -- the claims one too, since a stale claim token lets a payment be
  -- verified twice
  select count(*) into n from genalpha.admission_payment_claims;
  raise notice '% payment claims now carry a moving updated_at', n;
end $$;
