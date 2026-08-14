-- A reply rate that pools two different openers measures neither.
--
-- WHY NOW
--
-- Generation 1 of the opener went to 30 academies (A=13, B=17) and got zero
-- replies. 0/30 puts the true reply rate below roughly 12%, so the copy
-- changed on 2026-08-13. Generation 2 names a person instead of a company,
-- does not name the product, and asks one question with the answers supplied.
--
-- sales_ab_results() counted every outbound touch ever recorded. The moment
-- the new copy started sending, its number would have become a weighted
-- average of two different messages — and it would have looked like a single
-- clean statistic, which is worse than looking broken. The A/B arms stay
-- valid across the change (both arms always send identical text), but the
-- GENERATIONS must not be pooled.
--
-- HOW
--
-- The touch already records which opener sent it: sales.touches.template is
-- '<generation>_<arm>', written by the console from one SALES_GEN constant.
-- So the fix is to count the current generation only, and to report what was
-- set aside rather than dropping it silently — a bounded count that is not
-- stated reads as "we measured everything".
--
-- Replies are counted WITHOUT a generation filter on purpose: an inbound
-- WhatsApp message has no template, and a reply to generation 1 that lands
-- next week is still a reply to generation 1. It is attributed through the
-- lead's own outbound history instead.
--
-- Scope: shared. Operator-only.
--
-- No begin/commit: migrate.sh wraps this in one transaction.

create or replace function public.sales_ab_generation()
returns text language sql immutable as $$
  /* The opener the console is sending TODAY. Must match SALES_GEN in
     index.html. Bump both together, in the same change. */
  select 'opener2'
$$;

revoke execute on function public.sales_ab_generation() from public, anon;
grant  execute on function public.sales_ab_generation()
  to authenticated, service_role;

create or replace function public.sales_ab_results()
returns jsonb language plpgsql stable security definer
set search_path = public as $$
declare
  gen     text := sales_ab_generation();
  a_sent int; a_rep int; b_sent int; b_rep int;
  a_draft int; b_draft int; a_fail int; b_fail int;
  prev_sent int; prev_rep int;
  a_rate numeric; b_rate numeric; pooled numeric; se numeric; z numeric;
  mde numeric; verdict text;
begin
  perform assert_operator();

  /* DELIVERED attempts on the CURRENT opener only. A lead counts once, and
     only if it has an outbound touch that reached somebody — no draft, no
     one-tick failure, no wrong number. */
  select count(distinct t.lead_id) into a_sent from sales.touches t
    join sales.leads l on l.id = t.lead_id
   where t.direction = 'out' and not sales_undelivered(t.outcome)
     and t.template like gen || '\_%'
     and l.variant = 'A'
     and not exists (select 1 from sales.touches f
                      where f.lead_id = t.lead_id
                        and f.outcome in ('failed', 'wrong_number'));
  select count(distinct t.lead_id) into b_sent from sales.touches t
    join sales.leads l on l.id = t.lead_id
   where t.direction = 'out' and not sales_undelivered(t.outcome)
     and t.template like gen || '\_%'
     and l.variant = 'B'
     and not exists (select 1 from sales.touches f
                      where f.lead_id = t.lead_id
                        and f.outcome in ('failed', 'wrong_number'));

  select count(distinct t.lead_id) into a_draft from sales.touches t
    join sales.leads l on l.id = t.lead_id
   where t.outcome = 'opened' and t.template like gen || '\_%' and l.variant = 'A';
  select count(distinct t.lead_id) into b_draft from sales.touches t
    join sales.leads l on l.id = t.lead_id
   where t.outcome = 'opened' and t.template like gen || '\_%' and l.variant = 'B';

  select count(distinct t.lead_id) into a_fail from sales.touches t
    join sales.leads l on l.id = t.lead_id
   where t.outcome in ('failed', 'wrong_number') and l.variant = 'A';
  select count(distinct t.lead_id) into b_fail from sales.touches t
    join sales.leads l on l.id = t.lead_id
   where t.outcome in ('failed', 'wrong_number') and l.variant = 'B';

  /* A reply carries no template — an inbound message never had one — so it is
     attributed through the lead's own outbound history for this generation. */
  select count(distinct t.lead_id) into a_rep from sales.touches t
    join sales.leads l on l.id = t.lead_id
   where l.variant = 'A' and (t.direction = 'in' or t.outcome = 'replied')
     and exists (select 1 from sales.touches o
                  where o.lead_id = t.lead_id and o.direction = 'out'
                    and o.template like gen || '\_%');
  select count(distinct t.lead_id) into b_rep from sales.touches t
    join sales.leads l on l.id = t.lead_id
   where l.variant = 'B' and (t.direction = 'in' or t.outcome = 'replied')
     and exists (select 1 from sales.touches o
                  where o.lead_id = t.lead_id and o.direction = 'out'
                    and o.template like gen || '\_%');

  /* What this deliberately does NOT count. Say it out loud: a bounded number
     presented without its bound reads as the whole picture. */
  select count(distinct t.lead_id) into prev_sent from sales.touches t
   where t.direction = 'out' and not sales_undelivered(t.outcome)
     and coalesce(t.template, '') not like gen || '\_%';
  select count(distinct t.lead_id) into prev_rep from sales.touches t
   where (t.direction = 'in' or t.outcome = 'replied')
     and not exists (select 1 from sales.touches o
                      where o.lead_id = t.lead_id and o.direction = 'out'
                        and o.template like gen || '\_%');

  a_rate := case when a_sent > 0 then a_rep::numeric / a_sent end;
  b_rate := case when b_sent > 0 then b_rep::numeric / b_sent end;

  if a_sent >= 10 and b_sent >= 10 then
    pooled := (a_rep + b_rep)::numeric / (a_sent + b_sent);
    se := sqrt(greatest(pooled * (1 - pooled)
               * (1.0 / a_sent + 1.0 / b_sent), 1e-12));
    z := case when se > 0 then (b_rate - a_rate) / se end;
    mde := round(1.96 * se * 100, 1);
    verdict := case
      when abs(z) >= 1.96 then
        case when z > 0 then 'B wins — the screenshot earns replies'
             else 'A wins — the screenshot suppresses replies' end
      when abs(z) >= 1.28 then
        case when z > 0 then 'B leads, not yet conclusive — keep sending'
             else 'A leads, not yet conclusive — keep sending' end
      else 'no detectable difference at this sample size' end;
  else
    verdict := format('too early — need 10 DELIVERED per arm on %s (A=%s, B=%s)',
                      gen, a_sent, b_sent);
  end if;

  return jsonb_build_object(
    'generation', gen,
    'A', jsonb_build_object('label', 'text only',
           'assigned', (select count(*) from sales.leads
                         where variant = 'A' and not do_not_contact),
           'sent', a_sent, 'drafted', a_draft, 'undelivered', a_fail,
           'replied', a_rep,
           'reply_rate_pct', round(coalesce(a_rate, 0) * 100, 1)),
    'B', jsonb_build_object('label', 'text + one screenshot',
           'assigned', (select count(*) from sales.leads
                         where variant = 'B' and not do_not_contact),
           'sent', b_sent, 'drafted', b_draft, 'undelivered', b_fail,
           'replied', b_rep,
           'reply_rate_pct', round(coalesce(b_rate, 0) * 100, 1)),
    'difference_pct', round((coalesce(b_rate,0) - coalesce(a_rate,0)) * 100, 1),
    'min_detectable_pct', mde,
    'z', round(coalesce(z, 0), 2),
    'undelivered_total', a_fail + b_fail,
    -- earlier openers, excluded from the rates above but not hidden
    'earlier_openers', jsonb_build_object('delivered', prev_sent,
                                          'replied', prev_rep),
    'verdict', verdict);
end $$;

revoke execute on function public.sales_ab_results() from public, anon;
grant  execute on function public.sales_ab_results()
  to authenticated, service_role;

do $$
declare r jsonb; n int;
begin
  -- a new function is PUBLIC-executable until revoked, and revoking `anon`
  -- alone is a no-op
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname like 'sales\_%'
     and has_function_privilege('anon', p.oid, 'execute');
  if n > 0 then raise exception 'anon can execute % sales function(s)', n; end if;

  r := sales_ab_results();

  -- generation 2 has sent nothing yet, so both arms must read zero
  if (r->'A'->>'sent')::int <> 0 or (r->'B'->>'sent')::int <> 0 then
    raise exception 'a generation with no sends reports A=% B=%',
      r->'A'->>'sent', r->'B'->>'sent';
  end if;

  -- and the 30 generation-1 sends must be reported, not silently dropped
  if (r->'earlier_openers'->>'delivered')::int < 30 then
    raise exception 'earlier openers report % delivered, expected the 30 already sent',
      r->'earlier_openers'->>'delivered';
  end if;

  if (r->>'generation') <> 'opener2' then
    raise exception 'generation is %, expected opener2', r->>'generation';
  end if;

  raise notice 'A/B now measures % only; % earlier deliveries kept separate',
    r->>'generation', r->'earlier_openers'->>'delivered';
end $$;
