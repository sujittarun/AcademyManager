-- ============================================================
-- 2026-08-19l · fee rules become something a person can look at
-- scope: shared
--
-- WHY
-- fee_rules is the table that decides what every family pays, and until
-- today the only way to change a row in it was to write SQL. SKA is live
-- on two rules both labelled "placeholder — confirm with the academy",
-- which is fine only while somebody with a psql prompt is standing nearby.
--
-- WHAT THIS IS NOT
-- It is not a client that computes fees. resolve_fee() still owns every
-- amount; this only lets a manager EDIT the rules it reads, and every
-- number reported back is resolve_fee()'s own answer, asked per enrolment.
--
-- THE ONE NUMBER THAT MAKES THIS SAFE
-- A fee rule looks harmless — a label and an amount — and changing one
-- silently re-prices everybody it covers, including what the reminder
-- ladder quotes over WhatsApp tomorrow. So the board answers "how many
-- students is this rule pricing RIGHT NOW", and it answers it the only
-- honest way: by running resolve_fee() over every active enrolment and
-- seeing which rule_id comes back. Counting rows that merely LOOK like
-- they match would disagree with the chain the moment two rules overlap,
-- and disagreeing quietly is the whole failure mode here.
--
-- The same pass reports the two things a rules screen otherwise hides:
-- students on a per-student override (they ignore every rule) and
-- students the chain answers 'unset' for (they are charged nothing, and
-- nothing chases them).
--
-- ONE ACTIVE RULE PER SCOPE — the schema already says so, and the first
-- draft of this migration found out by violating it. fee_rules_scope_uniq
-- is UNIQUE on (tenant_id, centre, sport, batch, member) WHERE active.
-- Two consequences the screen has to respect rather than paper over:
--
--   * A second rule for a group that already has one is impossible, so
--     that mistake — the natural one on a screen like this — gets a
--     sentence naming the rule already there, not a raw 23505.
--   * A FEE RISE CANNOT BE SCHEDULED. "Morning 2500 until September" and
--     "Morning 2800 from October" are two active rules of one scope and
--     the index refuses the pair. So the screen offers no date fields and
--     says plainly that a change applies now. A date picker that always
--     errors, or one that leaves a batch priced by nothing until October,
--     are both worse than admitting the limit.
--
-- Widening that index is a shared-schema decision affecting six tenants,
-- and not something a screen should smuggle in.
--
-- ONE CALL, NOT FOUR. Tokyo is ~180ms from Coimbatore and the arithmetic
-- here is microseconds, so the board is a single round trip.
-- ============================================================

-- ------------------------------------------------------------
-- The board: every rule, plus what the chain actually does with it.
-- ------------------------------------------------------------
create or replace function public.fee_rules_board(p_tenant text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_rules jsonb; v_sum jsonb;
begin
  perform assert_staff(p_tenant);

  with live as (
    /* Active enrolments of members still on the roll — the population a
       fee rule can actually reach. A paused or discontinued enrolment is
       deliberately not counted: showing a rule as pricing 130 students
       when 40 of them left is the kind of number that gets believed. */
    select en.id, en.member_id, en.centre_id, en.sport,
           en.batch_id, en.plan_months, en.custom_amount
      from enrollments en
      join members m on m.id = en.member_id
     where en.tenant_id = p_tenant
       and en.status = 'active'
       and m.status <> 'discontinued'
  ),
  priced as (
    select l.id,
           resolve_fee(p_tenant, l.member_id, l.centre_id, l.sport,
                       l.batch_id, l.plan_months, l.custom_amount) as fee
      from live l
  ),
  flat as (
    select id,
           nullif(fee ->> 'rule_id', '')::bigint as rule_id,
           fee ->> 'source'                      as source,
           nullif(fee ->> 'monthly', '')::numeric as monthly
      from priced
  )
  select
    coalesce(jsonb_agg(to_jsonb(x) order by x.rank desc, x.effective_from desc, x.id desc), '[]'::jsonb)
    into v_rules
  from (
    select fr.id,
           fr.label,
           fr.note,
           fr.monthly_amount,
           fr.admission_fee,
           fr.plan_amounts,
           fr.effective_from,
           fr.effective_to,
           fr.active,
           fr.centre_id,
           fr.batch_id,
           fr.member_id,
           fr.sport,
           b.name  as batch_name,
           c.name  as centre_name,
           mm.name as member_name,
           fee_rule_rank(fr.*) as rank,
           /* What the chain calls this level, in the same words resolve_fee
              reports as `source`, so the screen and the toast agree. */
           case
             when fr.member_id is not null then 'member'
             when fr.batch_id  is not null then 'batch'
             when fr.centre_id is not null and fr.sport is not null then 'centre_sport'
             when fr.sport     is not null then 'sport'
             when fr.centre_id is not null then 'centre'
             else 'default' end as scope,
           /* Why it is or is not in play today — three different reasons a
              rule prices nobody, which the screen must not blur into one. */
           case
             when not fr.active                                          then 'off'
             when fr.effective_from > ist_today()                        then 'scheduled'
             when fr.effective_to is not null
                  and fr.effective_to < ist_today()                      then 'expired'
             else 'live' end as status,
           (select count(*) from flat f where f.rule_id = fr.id)::int as students
      from fee_rules fr
      left join batches b  on b.id  = fr.batch_id
      left join centres c  on c.id  = fr.centre_id
      left join members mm on mm.id = fr.member_id
     where fr.tenant_id = p_tenant
  ) x;

  with live as (
    select en.id, en.member_id, en.centre_id, en.sport,
           en.batch_id, en.plan_months, en.custom_amount
      from enrollments en
      join members m on m.id = en.member_id
     where en.tenant_id = p_tenant
       and en.status = 'active'
       and m.status <> 'discontinued'
  ),
  flat as (
    select nullif(fee ->> 'rule_id','')::bigint as rule_id,
           fee ->> 'source' as source,
           nullif(fee ->> 'monthly','')::numeric as monthly
      from (select resolve_fee(p_tenant, l.member_id, l.centre_id, l.sport,
                               l.batch_id, l.plan_months, l.custom_amount) as fee
              from live l) p
  )
  select jsonb_build_object(
           'students',   count(*),
           'unpriced',   count(*) filter (where source = 'unset'),
           'overridden', count(*) filter (where source = 'custom'),
           'monthly_total', coalesce(sum(monthly), 0))
    into v_sum
    from flat;

  return jsonb_build_object('rules', v_rules, 'summary', v_sum);
end
$function$;

revoke execute on function public.fee_rules_board(text) from public, anon;
grant  execute on function public.fee_rules_board(text) to authenticated, service_role;

-- ------------------------------------------------------------
-- Writing one. Create when p_id is null, otherwise update.
--
-- THE SCOPE ARGUMENTS ARE A FULL REPLACE, not a patch. A rule's scope is
-- WHO it prices, so a half-applied scope is a rule pricing a population
-- nobody chose; the screen loads a rule and sends all four back.
--
-- plan_amounts is deliberately NOT an argument. It prices multi-month
-- plans, no tenant on this platform uses it yet, and a save path that
-- silently wrote '{}' over it would erase a paying arrangement the first
-- time someone edited a label.
-- ------------------------------------------------------------
create or replace function public.save_fee_rule(
  p_tenant    text,
  p_id        bigint  default null,
  p_label     text    default null,
  p_monthly   numeric default null,
  p_admission numeric default 0,
  p_batch     bigint  default null,
  p_centre    bigint  default null,
  p_sport     text    default null,
  p_member    bigint  default null,
  p_from      date    default null,
  p_to        date    default null,
  p_active    boolean default true,
  p_note      text    default null,
  p_by        text    default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_from date; v_to date; v_id bigint; v_was fee_rules; v_new fee_rules;
  v_sport text; v_clash int; v_students int; v_dup text;
begin
  perform assert_staff(p_tenant);

  if length(trim(coalesce(p_label, ''))) < 2 then
    raise exception 'Give the rule a name — it is what the screen shows.';
  end if;
  if p_monthly is null then
    raise exception 'A monthly amount is required.';
  end if;
  if p_monthly < 0 or coalesce(p_admission, 0) < 0 then
    raise exception 'An amount cannot be negative.';
  end if;

  /* An UPDATE loads its row here, not later: both the dates below and the
     duplicate message further down need to know what was already there. */
  if p_id is not null then
    select * into v_was from fee_rules where id = p_id and tenant_id = p_tenant;
    if v_was.id is null then
      raise exception 'No such fee rule.';
    end if;
  end if;

  /* DATES ARE PRESERVED WHEN NOT GIVEN — the one place a null argument
     means "unchanged" rather than "none". The screen deliberately offers
     no date fields (see the header), so treating them as a full replace
     would reset every rule's start date to today on any edit: rewriting
     when it began, and shuffling the tie-break between competing rules on
     a screen that never mentioned dates. Scope, which the screen DOES
     send, stays a full replace. */
  v_from := coalesce(p_from, v_was.effective_from, ist_today());
  v_to   := coalesce(p_to,   v_was.effective_to);
  if v_to is not null and v_to < v_from then
    raise exception 'The end date is before the start date.';
  end if;

  /* THE CROSS-TENANT GUARD. Ids are global on this platform, so a batch id
     from another academy is a perfectly valid bigint — and a rule carrying
     one would be invisible to its owner and unreachable by its author. */
  if p_batch is not null and not exists (
       select 1 from batches where id = p_batch and tenant_id = p_tenant) then
    raise exception 'That batch does not belong to this academy.';
  end if;
  if p_centre is not null and not exists (
       select 1 from centres where id = p_centre and tenant_id = p_tenant) then
    raise exception 'That centre does not belong to this academy.';
  end if;
  if p_member is not null and not exists (
       select 1 from members where id = p_member and tenant_id = p_tenant) then
    raise exception 'That student does not belong to this academy.';
  end if;

  v_sport := nullif(btrim(coalesce(p_sport, '')), '');
  if v_sport is not null and not exists (
       select 1 from sports where tenant_id = p_tenant and code = v_sport) then
    raise exception 'This academy has no sport with the code %.', v_sport;
  end if;

  begin
    if p_id is null then
      insert into fee_rules (tenant_id, label, centre_id, sport, batch_id, member_id,
                             monthly_amount, admission_fee, effective_from, effective_to,
                             active, note)
      values (p_tenant, btrim(p_label), p_centre, v_sport, p_batch, p_member,
              p_monthly, coalesce(p_admission, 0), v_from, v_to,
              coalesce(p_active, true), nullif(btrim(coalesce(p_note,'')), ''))
      returning id into v_id;
    else
      update fee_rules
         set label          = btrim(p_label),
             centre_id      = p_centre,
             sport          = v_sport,
             batch_id       = p_batch,
             member_id      = p_member,
             monthly_amount = p_monthly,
             admission_fee  = coalesce(p_admission, 0),
             effective_from = v_from,
             effective_to   = v_to,
             active         = coalesce(p_active, true),
             note           = nullif(btrim(coalesce(p_note,'')), '')
       where id = p_id and tenant_id = p_tenant;
      v_id := p_id;
    end if;
  exception when unique_violation then
    /* fee_rules_scope_uniq. Name the rule that is already there — a
       manager who has just been told "23505 duplicate key" has been told
       nothing, and the fix is one click away on the same screen. */
    select label into v_dup from fee_rules
     where tenant_id = p_tenant and active
       and coalesce(centre_id, -1) = coalesce(p_centre, -1)
       and coalesce(sport, '')     = coalesce(v_sport, '')
       and coalesce(batch_id, -1)  = coalesce(p_batch, -1)
       and coalesce(member_id, -1) = coalesce(p_member, -1)
     limit 1;
    raise exception 'There is already a fee rule covering exactly that group%',
      case when v_dup is null then '.'
           else ' — "' || v_dup || '". Edit that one instead of adding a second.' end;
  end;

  select * into v_new from fee_rules where id = v_id;

  /* AN OVERLAP IS A WARNING, NOT AN ERROR. Two live rules at the same rank
     covering the same students are broken up by `effective_from desc, id
     desc` — a real answer, but an arbitrary one, and the screen should say
     so. Refusing would be wrong: writing the replacement before retiring
     the old one is the normal way to do this. */
  /* Comparing the two rules' scope COLUMNS for equality was the first
     attempt and it is wrong: SKA's rule 571 is batch 426 + centre 117,
     a new rule for batch 426 names no centre, and the columns therefore
     differ while both rules match exactly the same student at exactly the
     same rank. So ask the same question resolve_fee asks — is there a
     live enrolment BOTH rules match? — using its four tests verbatim.

     Two rules competing over a batch nobody is in are not reported, which
     is deliberate: nothing is mispriced until somebody is there. */
  select count(*) into v_clash
    from fee_rules fr
   where fr.tenant_id = p_tenant
     and fr.id <> v_id
     and fr.active
     and fee_rule_rank(fr.*) = fee_rule_rank(v_new.*)
     and fr.effective_from <= coalesce(v_new.effective_to, 'infinity'::date)
     and coalesce(fr.effective_to, 'infinity'::date) >= v_new.effective_from
     and exists (
       select 1
         from enrollments en
         join members m on m.id = en.member_id
        where en.tenant_id = p_tenant
          and en.status = 'active' and m.status <> 'discontinued'
          and (fr.member_id is null or fr.member_id = en.member_id)
          and (fr.batch_id  is null or fr.batch_id  = en.batch_id)
          and (fr.centre_id is null or fr.centre_id = en.centre_id)
          and (fr.sport     is null or fr.sport     = en.sport)
          and (v_new.member_id is null or v_new.member_id = en.member_id)
          and (v_new.batch_id  is null or v_new.batch_id  = en.batch_id)
          and (v_new.centre_id is null or v_new.centre_id = en.centre_id)
          and (v_new.sport     is null or v_new.sport     = en.sport));

  /* Asked of the chain AFTER the write, so it is what will actually
     happen rather than what was intended. */
  select count(*) into v_students
    from enrollments en
    join members m on m.id = en.member_id
   where en.tenant_id = p_tenant and en.status = 'active' and m.status <> 'discontinued'
     and (resolve_fee(p_tenant, en.member_id, en.centre_id, en.sport,
                      en.batch_id, en.plan_months, en.custom_amount) ->> 'rule_id')::bigint = v_id;

  /* The audit trail for a money change, in the shape sync_log already
     uses everywhere else: channel '*', a human sentence in `detail`.
     `detail` is TEXT, not jsonb — the first draft of this wrote an object
     and the NOT NULL on `channel` caught it in the dry run. Whoever reads
     this row later wants "2500 -> 2800", not a serialised row. */
  insert into sync_log (tenant_id, channel, action, status, detail)
  values (p_tenant, '*', 'fee_rule', 'ok',
          case when v_was.id is null
               then 'fee rule created: ' || v_new.label || ' at ' ||
                    trim(to_char(v_new.monthly_amount, 'FM999999990.00')) || '/month'
               else 'fee rule updated: ' || v_new.label || ' ' ||
                    trim(to_char(v_was.monthly_amount, 'FM999999990.00')) || ' -> ' ||
                    trim(to_char(v_new.monthly_amount, 'FM999999990.00')) || '/month'
          end || ' (rule ' || v_id || ', now pricing ' || v_students ||
          ' student(s)) by ' || coalesce(p_by, 'staff'));

  return jsonb_build_object('ok', true, 'id', v_id,
                            'created', (p_id is null),
                            'students', v_students,
                            'overlaps', v_clash);
end
$function$;

revoke execute on function public.save_fee_rule(text, bigint, text, numeric, numeric, bigint, bigint, text, bigint, date, date, boolean, text, text) from public, anon;
grant  execute on function public.save_fee_rule(text, bigint, text, numeric, numeric, bigint, bigint, text, bigint, date, date, boolean, text, text) to authenticated, service_role;

-- ------------------------------------------------------------
-- Retiring one. Never a DELETE: a fee rule is the reason a family was
-- charged what they were charged, and sync_log holds the before/after of
-- every change made through here. Deleting the row makes last month
-- unexplainable, and gains nothing — an inactive rule prices nobody.
-- ------------------------------------------------------------
create or replace function public.retire_fee_rule(
  p_tenant text,
  p_id     bigint,
  p_by     text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_was fee_rules; v_unpriced int;
begin
  perform assert_staff(p_tenant);

  select * into v_was from fee_rules where id = p_id and tenant_id = p_tenant;
  if v_was.id is null then raise exception 'No such fee rule.'; end if;

  update fee_rules set active = false where id = p_id and tenant_id = p_tenant;

  /* Counted after the update, inside the same transaction, so it is the
     real consequence: how many students are now priced by nothing at all
     and will therefore be charged nothing and chased for nothing. */
  select count(*) into v_unpriced
    from enrollments en
    join members m on m.id = en.member_id
   where en.tenant_id = p_tenant and en.status = 'active' and m.status <> 'discontinued'
     and (resolve_fee(p_tenant, en.member_id, en.centre_id, en.sport,
                      en.batch_id, en.plan_months, en.custom_amount) ->> 'source') = 'unset';

  insert into sync_log (tenant_id, channel, action, status, detail)
  values (p_tenant, '*', 'fee_rule', 'ok',
          'fee rule retired: ' || v_was.label || ' (was ' ||
          trim(to_char(v_was.monthly_amount, 'FM999999990.00')) || '/month); ' ||
          v_unpriced || ' student(s) now have no fee, by ' || coalesce(p_by, 'staff'));

  return jsonb_build_object('ok', true, 'id', p_id, 'unpriced', v_unpriced);
end
$function$;

revoke execute on function public.retire_fee_rule(text, bigint, text) from public, anon;
grant  execute on function public.retire_fee_rule(text, bigint, text) to authenticated, service_role;

-- ------------------------------------------------------------
-- Prove it, and clean up — this block writes and a real apply commits.
-- ------------------------------------------------------------
do $$
declare
  r jsonb; b jsonb; v_err text; v_batch bigint; v_batch2 bigint; v_centre bigint;
  v_id bigint; v_ids bigint[] := '{}'; v_rule jsonb; v_mid bigint; v_from date;
begin
  perform set_config('request.jwt.claims',
    '{"app_metadata":{"am_role":"staff","tenant_id":"ska"}}', true);
  select id into v_batch  from batches where tenant_id='ska' and code='MORNING';
  select id into v_batch2 from batches where tenant_id='ska' and code='EVENING';
  select id into v_centre from centres where tenant_id='ska' limit 1;

  -- 1. the board reads, and agrees with the chain about the live rule
  b := fee_rules_board('ska');
  if jsonb_array_length(b->'rules') < 2 then
    raise exception 'board returned % rules, expected the 2 SKA has',
      jsonb_array_length(b->'rules');
  end if;
  select x into v_rule from jsonb_array_elements(b->'rules') x
   where (x->>'id')::bigint = 571;
  if v_rule is null then raise exception 'rule 571 missing from the board'; end if;
  if v_rule->>'status' <> 'live' or v_rule->>'scope' <> 'batch' then
    raise exception 'rule 571 read as %/%', v_rule->>'status', v_rule->>'scope';
  end if;
  if (v_rule->>'students')::int <> 1 then
    raise exception 'rule 571 prices % students, expected the 1 live member',
      (v_rule->>'students')::int;
  end if;
  if (b->'summary'->>'unpriced')::int <> 0 then
    raise exception 'summary says % students are unpriced', b->'summary'->>'unpriced';
  end if;

  -- 2. create: a new batch rule, and the chain has to pick it up
  r := save_fee_rule('ska', null, 'ZZ Probe rule', 1234, 500, v_batch,
                     null, null, null, null, null, true, 'probe', 'probe');
  v_id := (r->>'id')::bigint; v_ids := v_ids || v_id;
  if (r->>'created')::boolean is not true then raise exception 'create not reported'; end if;
  /* Newer effective_from at the same rank wins the tie-break, so this must
     now be the rule pricing the live student — proving the board is
     reading the chain rather than pattern-matching the row. */
  if (r->>'students')::int <> 1 then
    raise exception 'the new rule prices % students, expected 1', r->>'students';
  end if;
  if (r->>'overlaps')::int < 1 then
    raise exception 'an overlapping rule was not reported';
  end if;

  -- 3. update: the amount changes; plan_amounts and the start date survive
  update fee_rules set plan_amounts = '{"3": 3300}'::jsonb,
                       effective_from = ist_today() - 40 where id = v_id;
  select effective_from into v_from from fee_rules where id = v_id;
  r := save_fee_rule('ska', v_id, 'ZZ Probe rule', 1500, 500, v_batch,
                     null, null, null, null, null, true, 'probe', 'probe');
  if (select monthly_amount from fee_rules where id = v_id) <> 1500 then
    raise exception 'the amount did not change';
  end if;
  if (select plan_amounts ->> '3' from fee_rules where id = v_id) <> '3300' then
    raise exception 'plan_amounts was clobbered by an edit that never mentioned it';
  end if;
  if (select effective_from from fee_rules where id = v_id) <> v_from then
    raise exception 'an edit that never mentioned dates moved the start date to %',
      (select effective_from from fee_rules where id = v_id);
  end if;

  -- 3b. a SECOND rule for the same group is refused, by name
  begin
    perform save_fee_rule('ska', null, 'ZZ Second morning', 111, 0, v_batch);
    raise exception 'a second active rule was created for one group';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err not like 'There is already a fee rule%' then raise; end if;
    if v_err not like '%ZZ Probe rule%' then
      raise exception 'the duplicate message did not name the rule already there: %', v_err;
    end if;
  end;

  -- 4. every cross-tenant scope is refused
  begin
    perform save_fee_rule('ska', null, 'ZZ Foreign batch', 100, 0, 1);
    raise exception 'accepted another academy''s batch';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err not like 'That batch does not%' then raise; end if;
  end;
  begin
    perform save_fee_rule('ska', null, 'ZZ Foreign centre', 100, 0, null, 1);
    raise exception 'accepted another academy''s centre';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err not like 'That centre does not%' then raise; end if;
  end;
  select id into v_mid from members where tenant_id <> 'ska' limit 1;
  if v_mid is not null then
    begin
      perform save_fee_rule('ska', null, 'ZZ Foreign member', 100, 0, null, null, null, v_mid);
      raise exception 'accepted another academy''s student';
    exception when others then
      get stacked diagnostics v_err = message_text;
      if v_err not like 'That student does not%' then raise; end if;
    end;
  end if;

  -- 5. nonsense is refused
  begin
    perform save_fee_rule('ska', null, 'ZZ Negative', -1);
    raise exception 'accepted a negative fee';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err not like 'An amount cannot be negative%' then raise; end if;
  end;
  begin
    perform save_fee_rule('ska', null, 'ZZ Backwards', 100, 0, null, null, null, null,
                          ist_today(), ist_today() - 1);
    raise exception 'accepted an end date before the start';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err not like 'The end date is before%' then raise; end if;
  end;
  begin
    perform save_fee_rule('ska', null, 'ZZ Nosport', 100, 0, null, null, 'kabaddi');
    raise exception 'accepted a sport this academy does not run';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err not like 'This academy has no sport%' then raise; end if;
  end;
  begin
    perform save_fee_rule('ska', 999999999, 'ZZ Ghost', 100);
    raise exception 'updated a rule that does not exist';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err not like 'No such fee rule%' then raise; end if;
  end;

  -- 6. a rule that starts later prices nobody until its day comes.
  --    On the EVENING batch: MORNING already has an active probe rule and
  --    fee_rules_scope_uniq allows exactly one per scope.
  r := save_fee_rule('ska', null, 'ZZ Future', 9999, 0, v_batch2, null, null, null,
                     ist_today() + 30, null, true, null, 'probe');
  v_ids := v_ids || (r->>'id')::bigint;
  if (r->>'students')::int <> 0 then
    raise exception 'a rule starting in 30 days is already pricing % students', r->>'students';
  end if;
  b := fee_rules_board('ska');
  select x into v_rule from jsonb_array_elements(b->'rules') x
   where (x->>'id')::bigint = (r->>'id')::bigint;
  if v_rule->>'status' <> 'scheduled' then
    raise exception 'a future rule reads as %', v_rule->>'status';
  end if;

  -- 7. retire: it stops pricing, and the row survives
  r := retire_fee_rule('ska', v_id, 'probe');
  if (select active from fee_rules where id = v_id) is not false then
    raise exception 'retire did not deactivate';
  end if;
  if not exists (select 1 from fee_rules where id = v_id) then
    raise exception 'retire DELETED the rule';
  end if;
  b := fee_rules_board('ska');
  select x into v_rule from jsonb_array_elements(b->'rules') x where (x->>'id')::bigint = v_id;
  if v_rule->>'status' <> 'off' or (v_rule->>'students')::int <> 0 then
    raise exception 'a retired rule still reads as %/% students',
      v_rule->>'status', v_rule->>'students';
  end if;

  -- 7b. the scope is free again once retired: the unique index is
  --     WHERE active, which is what makes replacing a rule possible at all
  r := save_fee_rule('ska', null, 'ZZ Replacement', 2222, 0, v_batch, null, null,
                     null, null, null, true, null, 'probe');
  v_ids := v_ids || (r->>'id')::bigint;
  perform retire_fee_rule('ska', (r->>'id')::bigint, 'probe');

  -- 8. and the original rule is pricing the student again
  b := fee_rules_board('ska');
  select x into v_rule from jsonb_array_elements(b->'rules') x where (x->>'id')::bigint = 571;
  if (v_rule->>'students')::int <> 1 then
    raise exception 'after retiring the probe, rule 571 prices %', v_rule->>'students';
  end if;

  -- CLEAN UP
  delete from fee_rules where tenant_id='ska' and id = any(v_ids);
  delete from sync_log where tenant_id='ska'
     and action = 'fee_rule' and detail like '%ZZ %';
  if exists (select 1 from fee_rules where tenant_id='ska' and label like 'ZZ %') then
    raise exception 'probe rules survived';
  end if;
  if (select count(*) from fee_rules where tenant_id='ska') <> 2 then
    raise exception 'SKA left with % fee rules, expected 2',
      (select count(*) from fee_rules where tenant_id='ska');
  end if;
end $$;
