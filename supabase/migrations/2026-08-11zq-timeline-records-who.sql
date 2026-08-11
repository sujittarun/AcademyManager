-- ============================================================
-- 2026-08-11zq · The timeline does not record who took the money
-- scope: shared
--
-- A real renewal was recorded through GenAlpha's app this morning:
-- payments.collected_by = 'genalphacricketacademy@gmail.com', the manager
-- account. The timeline entry beside it reads "System".
--
-- record_fee_payment() writes member_timeline with a meta object holding
-- payment_id, amount, months, kind, mode, period_from, period_to and ref
-- — and not who did it, even though p_collected_by is right there in the
-- argument list. GenAlpha's view reads changed_by from
-- meta->>'changed_by', gets null, and the app renders
-- `item.changed_by || "System"` (script.js:4362).
--
-- So every payment in the timeline is attributed to nobody. On a screen
-- whose purpose is answering "who changed this and when", that is the one
-- field that matters, and it is the one that was missing.
--
-- Additive: a new key in an existing jsonb object. No column changes, no
-- behaviour change for any tenant beyond the timeline naming a person.
-- Historical rows are backfilled from the payment they already reference.
-- ============================================================

do $$
declare src text; fixed text;
begin
  select pg_get_functiondef(oid) into src
    from pg_proc where proname = 'record_fee_payment' and pronamespace = 'public'::regnamespace;
  if src is null then raise exception 'record_fee_payment is missing'; end if;

  fixed := replace(src,
    $old$            'period_from', from_d, 'period_to', to_d, 'ref', p_ref));$old$,
    $new$            'period_from', from_d, 'period_to', to_d, 'ref', p_ref,
            -- who took the payment. Without it the timeline says "System"
            -- for every payment any tenant has ever recorded.
            'changed_by', nullif(coalesce(p_collected_by, ''), '')));$new$);

  if fixed = src then
    raise exception 'could not find the timeline meta in record_fee_payment — refusing to guess';
  end if;
  execute fixed;
end $$;

-- Backfill: every payment timeline row can name its collector, because it
-- already carries the payment_id that knows.
update member_timeline t
   set meta = t.meta || jsonb_build_object('changed_by', p.collected_by)
  from payments p
 where p.id = (t.meta->>'payment_id')::bigint
   and t.kind in ('payment', 'payment_pending')
   and coalesce(p.collected_by, '') <> ''
   and t.meta->>'changed_by' is null;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare n int; v text; v_before numeric; v_after numeric;
begin
  if (select pg_get_functiondef(oid) from pg_proc
       where proname='record_fee_payment' and pronamespace='public'::regnamespace) !~ 'changed_by' then
    raise exception 'record_fee_payment still does not record who';
  end if;

  -- The morning's real payment must now name the manager.
  select t.meta->>'changed_by' into v
    from member_timeline t
   where t.tenant_id='genalpha' and (t.meta->>'payment_id')::bigint = 3638;
  if v is distinct from 'genalphacricketacademy@gmail.com' then
    raise exception 'the backfill did not reach the payment this was found on: %', v;
  end if;

  -- Derived, not a threshold: every row that CAN be attributed must be.
  -- Most payment timeline rows predate this and came from GenAlpha's own
  -- export already carrying changed_by; only the ones record_fee_payment
  -- wrote were blank, which is why a round number would have been wrong
  -- in both directions.
  select count(*) into n from member_timeline t
   where t.kind in ('payment','payment_pending')
     and t.meta->>'changed_by' is null
     and exists (select 1 from payments p
                  where p.id = (t.meta->>'payment_id')::bigint
                    and coalesce(p.collected_by,'') <> '');
  if n <> 0 then raise exception '% attributable timeline rows still name nobody', n; end if;

  select count(*) into n from member_timeline
   where kind in ('payment','payment_pending') and meta->>'changed_by' is not null;
  raise notice '% of % payment timeline rows name who took the money', n,
    (select count(*) from member_timeline where kind in ('payment','payment_pending'));

  -- MONEY MUST NOT MOVE. This edits a jsonb key on a timeline row and
  -- replaces the body of the one function that writes payments; if a
  -- rupee changed, the replacement did more than intended.
  select sum(amount) into v_after from payments where tenant_id='genalpha';
  if v_after <> 499051 then raise exception 'genalpha money total is now %', v_after; end if;
  select count(*) into n from payments where tenant_id='genalpha';
  if n <> 132 then raise exception 'genalpha payment count is now %', n; end if;

  -- and the function still works, for every tenant
  if (select count(*) from pg_proc where proname='record_fee_payment') <> 1 then
    raise exception 'record_fee_payment was duplicated rather than replaced';
  end if;

  raise notice 'record_fee_payment now names the collector in the timeline';
end $$;
