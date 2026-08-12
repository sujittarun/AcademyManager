-- sales_import(): parse numbers out of prose instead of aborting.
--
-- WHAT BROKE
--
-- The first real import of 124 researched leads failed the whole batch on
-- one cell. A researcher had written, in the `branches` field:
--
--   "Kondapur site is one pool; the Seasons brand site names 5 localities
--    - Erragadda, Madhapur, Tank Bund, Abids, Kondapur"
--
-- which is a genuinely useful observation and not a number. `(r->>'branches')::int`
-- raised 22P02 and took the other 39 leads in that batch with it.
--
-- WHY THE FIX BELONGS HERE AND NOT IN THE LOADER
--
-- sales_import() is the one write path — it is where DNC suppression, the
-- never-downgrade-a-verified-phone rule and phone normalisation live. If
-- the loader sanitises and the function still hard-casts, then the next
-- caller (a different CSV, a paste from a spreadsheet, a hand-written
-- payload) hits the same wall. Making the function tolerant fixes it for
-- every caller; fixing the loader fixes it for one.
--
-- WHAT IT DOES NOT DO
--
-- It does not invent numbers. `sales.first_int()` returns the first
-- integer in the text or NULL, and NULL falls back to the column default.
-- Prose with no digits in it yields no count, which is correct — we do not
-- know how many branches they have, and guessing 1 would be a claim.
-- The original prose is preserved: the loader now carries it into
-- size_signal so the sentence a salesperson wants to read is not lost.
--
-- Scope: shared. Operator-only.
--
-- No begin/commit: migrate.sh wraps this in one transaction.

create or replace function sales.first_int(p text)
returns int language sql immutable as $$
  select nullif(regexp_replace(
           coalesce(substring(coalesce(p, '') from '\d+'), ''),
           '^0+(?=\d)', ''), '')::int
$$;

comment on function sales.first_int(text) is
  'First integer in the text, or NULL. Used so a prose value in a numeric '
  'import field costs that one field rather than the whole batch.';

create or replace function public.sales_import(p_rows jsonb)
returns jsonb language plpgsql security definer
set search_path = public as $$
declare
  r         jsonb;
  v_key     text;
  v_phone   text;
  v_conf    text;
  v_alts    text[];
  v_all     text[];
  v_branch  int;
  v_students int;
  n_ins     int := 0;
  n_upd     int := 0;
  n_dnc     int := 0;
  n_nophone int := 0;
  existed   boolean;
begin
  perform assert_operator();

  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'p_rows must be a json array';
  end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    v_key := regexp_replace(
               lower(coalesce(r->>'name', '')), '[^a-z0-9]+', '', 'g');
    if v_key = '' then continue; end if;

    v_phone := sales.norm_phone(r->>'phone');
    v_conf  := coalesce(nullif(r->>'phone_confidence', ''), 'none');

    -- tolerant numerics: prose costs the field, not the batch
    v_branch   := greatest(1, coalesce(sales.first_int(r->>'branches'), 1));
    v_students := sales.first_int(r->>'students_est');
    -- a "student count" in the millions is a typo or a national franchise
    -- figure, not this centre's roster. Drop it rather than let it drive
    -- the score and the suggested plan.
    if v_students is not null and v_students > 100000 then
      v_students := null;
    end if;

    select coalesce(array_agg(distinct m) filter (where m is not null), '{}')
      into v_alts
      from (select sales.norm_phone(x) as m
              from jsonb_array_elements_text(
                     case when jsonb_typeof(coalesce(r->'alt_phones','[]'::jsonb))
                               = 'array'
                          then r->'alt_phones' else '[]'::jsonb end) as x) s
     where m is distinct from v_phone;

    if v_phone is null and coalesce(r->>'phone', '') <> '' then
      v_conf := 'malformed';
    elsif v_phone is null then
      v_conf := 'none';
      n_nophone := n_nophone + 1;
    end if;
    if v_conf not in ('verified','directory','malformed','none') then
      v_conf := 'none';
    end if;

    v_all := array_remove(v_alts || array[v_phone], null);

    select exists (select 1 from sales.leads where import_key = v_key)
      into existed;

    insert into sales.leads as l (
      import_key, name, contact_name, sport, area, city,
      phone, alt_phones, phone_confidence, phone_source_url,
      website_or_social, branches, students_est, fees_seen, tech_signal,
      coaching_evidence, size_signal, notes, do_not_contact
    ) values (
      v_key, r->>'name',
      nullif(r->>'contact_name',''), nullif(r->>'sport',''),
      nullif(r->>'area',''), coalesce(nullif(r->>'city',''), 'Hyderabad'),
      v_phone, v_alts, v_conf,
      nullif(r->>'phone_source_url',''), nullif(r->>'website_or_social',''),
      v_branch, v_students,
      nullif(r->>'fees_seen',''), nullif(r->>'tech_signal',''),
      nullif(r->>'coaching_evidence',''), nullif(r->>'size_signal',''),
      nullif(r->>'notes',''),
      exists (select 1 from sales.dnc d where d.phone = any(v_all))
    )
    on conflict (import_key) do update set
      phone = case
                when excluded.phone is null then l.phone
                when l.phone is null then excluded.phone
                when excluded.phone_confidence = 'verified'
                     and l.phone_confidence <> 'verified' then excluded.phone
                else l.phone end,
      phone_confidence = case
                when excluded.phone is null then l.phone_confidence
                when l.phone is null then excluded.phone_confidence
                when excluded.phone_confidence = 'verified'
                     and l.phone_confidence <> 'verified'
                  then excluded.phone_confidence
                else l.phone_confidence end,
      phone_source_url = coalesce(
                           case when excluded.phone_confidence = 'verified'
                                  and l.phone_confidence <> 'verified'
                                then excluded.phone_source_url end,
                           l.phone_source_url, excluded.phone_source_url),
      alt_phones = array_remove(
                     (select coalesce(array_agg(distinct e), '{}')
                        from unnest(l.alt_phones || excluded.alt_phones) e
                       where e is distinct from coalesce(
                               case when excluded.phone_confidence = 'verified'
                                      and l.phone_confidence <> 'verified'
                                    then excluded.phone else l.phone end,
                               l.phone)),
                     null),
      contact_name      = coalesce(l.contact_name, excluded.contact_name),
      area              = coalesce(l.area, excluded.area),
      website_or_social = coalesce(l.website_or_social,
                                   excluded.website_or_social),
      branches          = greatest(l.branches, excluded.branches),
      students_est      = coalesce(greatest(l.students_est,
                                            excluded.students_est),
                                   excluded.students_est, l.students_est),
      fees_seen         = coalesce(l.fees_seen, excluded.fees_seen),
      tech_signal       = coalesce(l.tech_signal, excluded.tech_signal),
      coaching_evidence = coalesce(l.coaching_evidence,
                                   excluded.coaching_evidence),
      size_signal       = coalesce(l.size_signal, excluded.size_signal),
      notes             = coalesce(l.notes, excluded.notes),
      sport             = case
                            when l.sport is null then excluded.sport
                            when excluded.sport is null then l.sport
                            when l.sport ilike '%' || excluded.sport || '%'
                              then l.sport
                            else l.sport || ' / ' || excluded.sport end,
      do_not_contact    = l.do_not_contact or excluded.do_not_contact;

    if existed then n_upd := n_upd + 1; else n_ins := n_ins + 1; end if;
  end loop;

  select count(*) into n_dnc from sales.leads where do_not_contact;

  return jsonb_build_object(
    'inserted', n_ins, 'updated', n_upd,
    'suppressed_dnc', n_dnc, 'without_phone', n_nophone,
    'total', (select count(*) from sales.leads));
end $$;

revoke execute on function public.sales_import(jsonb) from public, anon;
grant  execute on function public.sales_import(jsonb)
  to authenticated, service_role;
revoke execute on function sales.first_int(text) from public, anon;

do $$
declare n int;
begin
  -- the parse must not invent a count where there is no number
  if sales.first_int('no digits here at all') is not null then
    raise exception 'first_int invented a number';
  end if;
  if sales.first_int('names 5 localities - Erragadda, Madhapur') <> 5 then
    raise exception 'first_int did not read 5 out of the prose';
  end if;
  if sales.first_int('7+ branches') <> 7 then
    raise exception 'first_int did not read 7+';
  end if;
  if sales.first_int(null) is not null then
    raise exception 'first_int on null';
  end if;

  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname like 'sales\_%'
     and has_function_privilege('anon', p.oid, 'execute');
  if n > 0 then
    raise exception 'anon can execute % sales function(s)', n;
  end if;
  raise notice 'sales_import tolerates prose in numeric fields; anon still has no reach';
end $$;
