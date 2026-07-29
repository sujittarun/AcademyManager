-- ============================================================
-- 0016 · "Match Point Pride"
-- scope: mpp
--
-- The console shows tenants.name verbatim. "Match Point Pride Badminton
-- Academy" is the legal name; the short one is what the operator reads
-- forty times a day.
--
-- Nothing keys off name — every reference is tenant_id — so this is
-- display only.
-- ============================================================

update tenants set name = 'Match Point Pride' where id = 'mpp';

do $$
begin
  if (select name from tenants where id = 'mpp') <> 'Match Point Pride' then
    raise exception 'rename did not apply';
  end if;
end $$;
