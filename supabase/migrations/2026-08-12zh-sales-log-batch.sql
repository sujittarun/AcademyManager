-- Log a batch of drafts in one round-trip.
--
-- WHY
--
-- Batch-open opens ten prospects' chats at once. Logging them one at a time
-- is ten sequential RPCs, and PLATFORM.md is explicit that the only
-- optimisation that matters on this platform is fewer round-trips: the
-- database answers in single-digit milliseconds while a call from Hyderabad
-- to ap-northeast-1 costs ~180ms. Ten calls is ~1.8s of pure latency before
-- the operator's first tab is usable.
--
-- WHY IT DELEGATES TO sales_log_touch()
--
-- The stage machine — draft does not advance, a send does, a reply wins, a
-- refusal loses — lives in sales_log_touch(). Reimplementing it here would
-- create a second authority that can disagree with the first, which is the
-- thing the house rule exists to prevent. So this loops and calls it, and
-- gets the DNC refusal and the arm defaulting for free.
--
-- WHY IT SKIPS RATHER THAN RAISES
--
-- sales_log_touch() raises on a do-not-contact lead, which is correct for a
-- single deliberate action. In a batch that would abort the other nine. Here
-- each lead is attempted independently and refusals are counted and returned,
-- so the operator sees "9 logged, 1 skipped (do-not-contact)" instead of an
-- error and no idea which ones landed.
--
-- Scope: shared. Operator-only.
--
-- No begin/commit: migrate.sh wraps this in one transaction.

create or replace function public.sales_log_batch(
  p_leads     uuid[],
  p_channel   text default 'whatsapp',
  p_outcome   text default 'opened',
  p_direction text default 'out',
  p_template  text default null,
  p_sent_from text default null
) returns jsonb language plpgsql security definer
set search_path = public as $$
declare
  v_lead   uuid;
  v_res    jsonb;
  n_ok     int := 0;
  n_skip   int := 0;
  v_skipped jsonb := '[]'::jsonb;
  v_done    jsonb := '[]'::jsonb;
begin
  perform assert_operator();

  if p_leads is null or array_length(p_leads, 1) is null then
    return jsonb_build_object('logged', 0, 'skipped', 0,
                              'leads', '[]'::jsonb, 'skipped_leads', '[]'::jsonb);
  end if;
  -- a batch is a human clicking a button, not an import: cap it so a bug
  -- cannot mark the whole pipeline contacted in one call
  if array_length(p_leads, 1) > 50 then
    raise exception 'batch of % refused; open at most 50 at a time',
      array_length(p_leads, 1);
  end if;

  foreach v_lead in array p_leads loop
    begin
      -- one authority for the stage machine: call the single-touch function
      v_res := sales_log_touch(
                 p_lead      := v_lead,
                 p_channel   := p_channel,
                 p_outcome   := p_outcome,
                 p_direction := p_direction,
                 p_template  := p_template,
                 p_sent_from := p_sent_from);
      n_ok := n_ok + 1;
      v_done := v_done || jsonb_build_array(
        jsonb_build_object('lead', v_lead, 'stage', v_res->>'stage',
                           'variant', v_res->>'variant'));
    exception when others then
      -- do-not-contact, or a lead deleted between render and click
      n_skip := n_skip + 1;
      v_skipped := v_skipped || jsonb_build_array(
        jsonb_build_object('lead', v_lead, 'why', sqlerrm));
    end;
  end loop;

  return jsonb_build_object(
    'logged', n_ok, 'skipped', n_skip,
    'leads', v_done, 'skipped_leads', v_skipped);
end $$;

comment on function public.sales_log_batch(uuid[], text, text, text, text, text) is
  'Logs one touch per lead in a single round-trip, delegating each to '
  'sales_log_touch() so the stage machine has one authority. Skips and '
  'reports do-not-contact leads rather than aborting the batch. Capped at 50.';

revoke execute on function
  public.sales_log_batch(uuid[], text, text, text, text, text) from public, anon;
grant  execute on function
  public.sales_log_batch(uuid[], text, text, text, text, text)
  to authenticated, service_role;

do $$
declare ids uuid[]; r jsonb; n int; v_dnc uuid;
begin
  -- anon must not reach it
  if has_function_privilege('anon',
       'public.sales_log_batch(uuid[],text,text,text,text,text)', 'execute') then
    raise exception 'anon can execute sales_log_batch';
  end if;

  -- an empty batch is a no-op, not an error
  r := sales_log_batch('{}'::uuid[]);
  if (r->>'logged')::int <> 0 then raise exception 'empty batch logged something'; end if;

  -- and the cap holds
  begin
    perform sales_log_batch(array_fill('00000000-0000-0000-0000-000000000000'::uuid,
                                       array[51]));
    raise exception 'a batch of 51 was accepted';
  exception when others then
    if sqlerrm !~ 'refused' then raise; end if;
  end;

  -- a batch of unknown ids must skip, not raise
  r := sales_log_batch(array['00000000-0000-0000-0000-000000000000'::uuid]);
  if (r->>'skipped')::int <> 1 then
    raise exception 'an unknown lead id was not skipped';
  end if;

  raise notice 'sales_log_batch: one round-trip, skips instead of aborting, capped at 50';
end $$;
