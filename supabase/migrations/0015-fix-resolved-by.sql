-- ============================================================
-- 0015 · Record who resolved an error
-- scope: shared
--
-- 0013 wrote:
--
--   coalesce(nullif(auth.jwt() ->> 'email', ''), auth_role(), 'service')
--
-- auth_role() returns '' — not null — when there are no JWT claims, so
-- it satisfies coalesce and the fallback never runs. Every
-- service-side resolve was stored with resolved_by = ''.
--
-- Caught by reading the row back after the first real resolve rather
-- than by trusting the expression. A blank audit field is worse than an
-- absent one: it looks like an answer.
-- ============================================================

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

  -- nullif on BOTH, because auth_role() returns '' rather than null.
  v_who := coalesce(
             nullif(auth.jwt() ->> 'email', ''),
             nullif(auth_role(), ''),
             'service');

  insert into error_acks (tenant_id, msg, ver, resolved_through, resolved_by, note)
  values (p_tenant, p_msg, p_ver, v_through, v_who, p_note)
  on conflict (tenant_id, msg, ver) do update
     set resolved_through = excluded.resolved_through,
         resolved_by      = excluded.resolved_by,
         resolved_at      = now(),
         note             = coalesce(excluded.note, error_acks.note);

  return jsonb_build_object('ok', true, 'resolved_through', v_through, 'by', v_who);
end $function$;

revoke execute on function public.resolve_client_error(text,text,text,text) from public, anon;
grant execute on function public.resolve_client_error(text,text,text,text) to authenticated, service_role;

-- Existing blanks are from the same bug; there is no way to recover who
-- it was, so say so rather than leaving an empty string.
update error_acks set resolved_by = 'unknown (pre-0015)'
 where resolved_by is null or resolved_by = '';

do $$
declare v_who text;
begin
  insert into events (tenant_id, name, session_id, page, props, at)
  values ('mpp','client_error','who-selftest','#/x',
          jsonb_build_object('msg','ZZ-selftest-0015','ver','9.9'), now());

  perform resolve_client_error('mpp','ZZ-selftest-0015','9.9',null);
  select resolved_by into v_who from error_acks
   where tenant_id='mpp' and msg='ZZ-selftest-0015';

  if coalesce(v_who,'') = '' then
    raise exception 'resolved_by is still blank';
  end if;
  raise notice 'resolved_by = %', v_who;

  delete from error_acks where tenant_id='mpp' and msg='ZZ-selftest-0015';
  delete from events where session_id='who-selftest';
end $$;
