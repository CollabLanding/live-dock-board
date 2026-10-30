begin;
alter table public.trailers add column is_downed boolean not null default false;
create or replace function dock_private.save_trailer_with_status(p_id uuid,p_number text,p_category text,p_location_label text,p_notes text,p_expected_updated_at timestamptz,p_is_downed boolean)
returns public.trailers language plpgsql security definer set search_path='' as $$
declare t public.trailers;
begin
 if auth.uid() is null or dock_private.role() not in ('Owner','Admin') then raise exception 'Admin access required' using errcode='42501';end if;
 t:=dock_private.save_trailer(p_id,p_number,p_category,p_location_label,p_notes,p_expected_updated_at);
 update public.trailers set is_downed=coalesce(p_is_downed,false),updated_at=clock_timestamp(),updated_by=auth.uid() where id=t.id returning * into t;
 return t;
end $$;
revoke all on function dock_private.save_trailer_with_status(uuid,text,text,text,text,timestamptz,boolean) from public,anon;
grant execute on function dock_private.save_trailer_with_status(uuid,text,text,text,text,timestamptz,boolean) to authenticated;
create or replace function public.save_trailer_with_status(p_id uuid,p_number text,p_category text,p_location_label text,p_notes text,p_expected_updated_at timestamptz,p_is_downed boolean)
returns public.trailers language sql security invoker set search_path='' as $$
 select dock_private.save_trailer_with_status(p_id,p_number,p_category,p_location_label,p_notes,p_expected_updated_at,p_is_downed);
$$;
revoke all on function public.save_trailer_with_status(uuid,text,text,text,text,timestamptz,boolean) from public,anon;
grant execute on function public.save_trailer_with_status(uuid,text,text,text,text,timestamptz,boolean) to authenticated;
commit;