-- ============================================================
-- 0013 · Let the operator mark a client error resolved
-- scope: shared
--
-- platform_errors() reports every distinct client error in a window.
-- Once a bug is fixed there is nothing to do about the rows already in
-- `events`, so the banner keeps accusing you of a bug that no longer
-- exists — and a warning that never clears is a warning nobody reads.
--
-- Acknowledgement is recorded per (tenant, message, version), not per
-- event row, because that is the grain the operator actually thinks in:
-- "that one is fixed", not "those forty-one rows are fixed".
--
-- THE PART THAT MATTERS
--
-- Resolving stores the timestamp of the newest occurrence seen at that
-- moment — `resolved_through` — rather than a boolean. A LATER
-- occurrence has a timestamp past it, so the error comes straight back.
-- A dismissal that silenced a recurring fault permanently would be
-- worse than no dismissal at all: it would turn a loud bug into a quiet
-- one, which is the failure mode this whole pipe exists to prevent.
--
-- Version is part of the key on purpose. The same message from a new
-- build is a new fact — it means the fix did not take.
-- ============================================================

create table if not exists public.error_acks (
  id               bigserial primary key,
  tenant_id        text        not null,
  -- the grouped message exactly as platform_errors() reports it
  msg              text        not null,
  ver              text        not null,
  -- resolved up to and including this instant; anything newer reappears
  resolved_through timestamptz not null,
  resolved_by      text,
  resolved_at      timestamptz not null default now(),
  note             text,
  unique (tenant_id, msg, ver)
);

comment on table public.error_acks is
  'Operator acknowledgements of client errors. resolved_through, not a boolean, so a recurrence reappears.';

alter table public.error_acks enable row level security;

-- Reached only through the functions below, which are SECURITY DEFINER
-- and carry their own checks. No direct client access.
revoke all on public.error_acks from anon, authenticated;
revoke all on sequence public.error_acks_id_seq from anon, authenticated;

drop policy if exists error_acks_service on public.error_acks;
create policy error_acks_service on public.error_acks
  for all to service_role using (true) with check (true);

-- ------------------------------------------------------------
-- platform_errors(): same shape as before, minus anything resolved
-- whose newest occurrence predates the acknowledgement.
-- ------------------------------------------------------------
create or replace function public.platform_errors(p_hours int default 24)
returns table (
  tenant_id   text,
  msg         text,
  ver         text,
  occurrences bigint,
  affected_sessions bigint,
  first_seen  timestamptz,
  last_seen   timestamptz,
  sample_page text,
  sample_src  text
)
language sql
stable
security definer
set search_path to 'public'
as $$
  with grouped as (
    select e.tenant_id,
           left(coalesce(e.props ->> 'msg', '(no message)'), 90) as msg,
           coalesce(e.props ->> 'ver', '?')                      as ver,
           count(*)                                              as occurrences,
           count(distinct e.session_id)                          as affected_sessions,
           min(e.at)                                             as first_seen,
           max(e.at)                                             as last_seen,
           (array_agg(e.page order by e.at desc))[1]             as sample_page,
           (array_agg(e.props ->> 'src' order by e.at desc))[1]  as sample_src
      from events e
     where e.name = 'client_error'
       and e.at > now() - make_interval(hours => greatest(p_hours, 1))
     group by 1, 2, 3
  )
  select g.tenant_id, g.msg, g.ver, g.occurrences, g.affected_sessions,
         g.first_seen, g.last_seen, g.sample_page, g.sample_src
    from grouped g
    left join error_acks a
      on a.tenant_id = g.tenant_id and a.msg = g.msg and a.ver = g.ver
   where a.id is null or g.last_seen > a.resolved_through
   order by g.last_seen desc
$$;

comment on function public.platform_errors(int) is
  'Unresolved distinct client errors per tenant in the last N hours, newest first.';

revoke execute on function public.platform_errors(int) from public, anon, authenticated;
grant execute on function public.platform_errors(int) to service_role;

-- ------------------------------------------------------------
-- resolve_client_error(): the button.
--
-- Idempotent, and re-resolving an error that came back simply moves the
-- line forward to now.
-- ------------------------------------------------------------
create or replace function public.resolve_client_error(
  p_tenant text,
  p_msg    text,
  p_ver    text,
  p_note   text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_through timestamptz; v_who text;
begin
  -- Operator, or staff of that tenant. Not anon, ever.
  perform assert_staff_or_service(p_tenant);

  select max(e.at) into v_through
    from events e
   where e.tenant_id = p_tenant
     and e.name = 'client_error'
     and left(coalesce(e.props ->> 'msg', '(no message)'), 90) = p_msg
     and coalesce(e.props ->> 'ver', '?') = p_ver;

  if v_through is null then
    return jsonb_build_object('ok', false, 'reason', 'no such error');
  end if;

  v_who := coalesce(nullif(auth.jwt() ->> 'email', ''), auth_role(), 'service');

  insert into error_acks (tenant_id, msg, ver, resolved_through, resolved_by, note)
  values (p_tenant, p_msg, p_ver, v_through, v_who, p_note)
  on conflict (tenant_id, msg, ver) do update
     set resolved_through = excluded.resolved_through,
         resolved_by      = excluded.resolved_by,
         resolved_at      = now(),
         note             = coalesce(excluded.note, error_acks.note);

  return jsonb_build_object('ok', true, 'resolved_through', v_through, 'by', v_who);
end $function$;

comment on function public.resolve_client_error(text,text,text,text) is
  'Mark a client error resolved up to its newest occurrence. A later occurrence reappears.';

revoke execute on function public.resolve_client_error(text,text,text,text) from public, anon;
grant execute on function public.resolve_client_error(text,text,text,text) to authenticated, service_role;

-- ------------------------------------------------------------
-- reopen_client_error(): undo, for the misfire.
-- ------------------------------------------------------------
create or replace function public.reopen_client_error(
  p_tenant text, p_msg text, p_ver text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_n int;
begin
  perform assert_staff_or_service(p_tenant);
  delete from error_acks
   where tenant_id = p_tenant and msg = p_msg and ver = p_ver;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', v_n > 0);
end $function$;

revoke execute on function public.reopen_client_error(text,text,text) from public, anon;
grant execute on function public.reopen_client_error(text,text,text) to authenticated, service_role;

-- ------------------------------------------------------------
-- Prove the behaviour, including the part that matters, then roll the
-- fixture back. A boolean-dismiss bug would pass a naive test; this one
-- checks that a NEWER occurrence reappears.
-- ------------------------------------------------------------
do $$
declare
  v_msg text := 'ZZ-selftest-0013 synthetic error';
  v_n   int;
begin
  insert into events (tenant_id, name, session_id, page, props, at)
  values ('mpp','client_error','ack-selftest','#/x',
          jsonb_build_object('msg', v_msg, 'ver','9.9','kind','operation'),
          now() - interval '5 minutes');

  select count(*) into v_n from platform_errors(1)
   where tenant_id='mpp' and msg = v_msg;
  if v_n <> 1 then raise exception 'fixture not visible before resolve (got %)', v_n; end if;

  perform resolve_client_error('mpp', v_msg, '9.9', 'selftest');

  select count(*) into v_n from platform_errors(1)
   where tenant_id='mpp' and msg = v_msg;
  if v_n <> 0 then raise exception 'still visible after resolve (got %)', v_n; end if;

  -- the same fault happens again, AFTER the acknowledgement
  insert into events (tenant_id, name, session_id, page, props, at)
  values ('mpp','client_error','ack-selftest-2','#/x',
          jsonb_build_object('msg', v_msg, 'ver','9.9','kind','operation'),
          now());

  select count(*) into v_n from platform_errors(1)
   where tenant_id='mpp' and msg = v_msg;
  if v_n <> 1 then
    raise exception 'a RECURRENCE stayed hidden — dismissal is silencing live bugs (got %)', v_n;
  end if;

  -- and reopen puts it back unconditionally
  perform resolve_client_error('mpp', v_msg, '9.9', null);
  perform reopen_client_error('mpp', v_msg, '9.9');
  select count(*) into v_n from platform_errors(1)
   where tenant_id='mpp' and msg = v_msg;
  if v_n <> 1 then raise exception 'reopen did not restore the error (got %)', v_n; end if;

  delete from error_acks where tenant_id='mpp' and msg = v_msg;
  delete from events where session_id like 'ack-selftest%';
  raise notice '0013 selftest passed';
end $$;
