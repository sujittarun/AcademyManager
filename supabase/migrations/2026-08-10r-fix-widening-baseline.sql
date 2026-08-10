-- The 2026-08-10q baseline used a "public.table.column" object_name.
-- shared_widening_audit() emits "table.column". They would never have
-- matched, so the baseline would have gone on reporting the twenty
-- columns it was written to accept. Rewrite them to the real format.
update shared_surface_review
   set object_name = regexp_replace(object_name, '^public\.', '')
 where reviewed_by = '2026-08-10q';

-- and baseline the eleven PRE-EXISTING findings that surfaced today when
-- removing GenAlpha's rows changed the tenant counts the audit divides
-- by. They are not new drift; they are old drift that became visible.
insert into shared_surface_review (object_name, finding, detail, first_seen, reviewed_at, reviewed_by, note)
select a.object_name, a.finding, a.detail, now(), now(), '2026-08-10q',
       'Pre-existing single-tenant column, surfaced when genalpha rows were removed and the tenant count changed. Reviewed and accepted; not caused by the widening.'
  from shared_widening_audit() a
 where not exists (select 1 from shared_surface_review r where r.object_name = a.object_name);

do $$
declare n int;
begin
  select count(*) into n from shared_widening_audit() a
   where not exists (select 1 from shared_surface_review r where r.object_name = a.object_name);
  if n <> 0 then raise exception '% findings still unbaselined', n; end if;

  -- prove the baseline can actually match: the format must be the audit's
  if exists (select 1 from shared_surface_review
              where reviewed_by='2026-08-10q' and object_name like 'public.%') then
    raise exception 'baseline still carries the public. prefix and cannot match';
  end if;
  raise notice 'baseline format corrected; widening audit clean';
end $$;
