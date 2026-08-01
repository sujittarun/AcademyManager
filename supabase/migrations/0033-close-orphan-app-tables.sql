-- ============================================================
-- 0033 · Close the orphan app tables: memories, push_subscriptions
-- scope: shared
--
-- Found auditing tenant `mpp` (2026-07-31): both tables carry RLS with
-- {public}-role policies whose predicate is literally `true`. Confirmed
-- with a live GET using the committed anon key — memories returned its
-- rows ("Feed the dog", "Practice piano") to anyone holding the public
-- key; push_subscriptions accepted anonymous INSERT/UPDATE/DELETE.
--
-- They belong to the "Suhas - Remembering App", which no longer uses
-- Supabase at all: its server/main.ts runs on Deno KV and says so —
-- "replacing the retired Supabase project (free tier exhausted)" — and
-- its client code contains zero Supabase references. The tables are
-- leftovers of a retired integration sharing the platform project.
--
-- Decision: CLOSE, don't drop. The rows are someone's personal data and
-- dropping them is not reversible; locking them achieves the security
-- goal (anon can no longer read, write, or wipe them) and leaves the
-- drop as an explicit human decision later.
--
-- Neither table is read by any tenant app or named in any policy, so
-- the is_locked() failure mode (revoking something a policy or an anon
-- path needs) does not apply. Verified by the self-check below and by
-- exercising the real paths after apply.
-- ============================================================

-- Drop every policy on both tables, whatever they were named.
do $$
declare p record;
begin
  for p in
    select policyname, tablename
      from pg_policies
     where schemaname = 'public'
       and tablename in ('memories', 'push_subscriptions')
  loop
    execute format('drop policy %I on public.%I', p.policyname, p.tablename);
  end loop;
end $$;

-- RLS stays on (default deny), and the table grants go too — a policy
-- is only half the gate; the ACL is the other half. Guarded on
-- existence so the file also applies cleanly to an environment that
-- never had the orphan tables.
do $$
begin
  if to_regclass('public.memories') is not null then
    execute 'alter table public.memories enable row level security';
    execute 'revoke all on table public.memories from public, anon, authenticated';
  end if;
  if to_regclass('public.push_subscriptions') is not null then
    execute 'alter table public.push_subscriptions enable row level security';
    execute 'revoke all on table public.push_subscriptions from public, anon, authenticated';
  end if;
end $$;

-- ------------------------------------------------------------
-- Self-check: fail the migration if either table is still reachable.
-- Same pattern as 0024 — become anon and try, in this transaction.
-- ------------------------------------------------------------
do $$
declare v_n int;
begin
  -- no policies may remain
  select count(*) into v_n
    from pg_policies
   where schemaname = 'public'
     and tablename in ('memories', 'push_subscriptions');
  if v_n > 0 then
    raise exception 'still % open policies on the orphan tables', v_n;
  end if;

  set local role anon;
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);

  if to_regclass('public.memories') is not null then
    begin
      execute 'select count(*) from public.memories' into v_n;
      raise exception 'PROBE: anon can still read memories (% rows)', v_n;
    exception
      when insufficient_privilege then null;   -- the outcome we want
    end;
  end if;

  if to_regclass('public.push_subscriptions') is not null then
    begin
      execute $probe$insert into public.push_subscriptions (endpoint, p256dh, auth)
        values ('probe://denied', 'x', 'y')$probe$;
      raise exception 'PROBE: anon can still insert into push_subscriptions';
    exception
      when insufficient_privilege then null;   -- the outcome we want
    end;
  end if;

  reset role;
  raise notice 'orphan tables closed: no policies, anon denied on read and write';
end $$;
