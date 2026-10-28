-- Applied to the LTB database. Open status updates release assigned trailers atomically.
begin;
create or replace function dock_private.clear_trailer_when_open()
returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if new.status='Open Dock' then new.trailer_number:=null; end if;
 return new;
end;
$$;
revoke all on function dock_private.clear_trailer_when_open() from public;
create or replace trigger b_clear_trailer_when_open before update of status on public.docks
for each row execute function dock_private.clear_trailer_when_open();
-- Include releases made by BEFORE triggers, not just explicit trailer edits.
create or replace trigger log_trailer_assignment after update on public.docks
for each row when (old.trailer_number is distinct from new.trailer_number)
execute function dock_private.log_trailer_activity();
commit;