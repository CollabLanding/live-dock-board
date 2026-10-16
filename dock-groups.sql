create table public.dock_groups (
 id uuid primary key default gen_random_uuid(), building integer not null check(building in (100,200)),
 title text not null check(length(btrim(title)) between 1 and 80),
 dock_ids uuid[] not null check(cardinality(dock_ids) between 1 and 100),
 revision bigint not null default 1, updated_at timestamptz not null default now()
);
create unique index dock_groups_title on public.dock_groups(building,lower(title));
alter table public.dock_groups enable row level security;
grant select,insert,update,delete on public.dock_groups to authenticated;
create policy group_read on public.dock_groups for select to authenticated using(dock_private.can('view_board'));
create policy group_create on public.dock_groups for insert to authenticated with check((public.get_dock_access()->>'role') in ('Owner','Admin'));
create policy group_update on public.dock_groups for update to authenticated using((public.get_dock_access()->>'role') in ('Owner','Admin')) with check((public.get_dock_access()->>'role') in ('Owner','Admin'));
create policy group_delete on public.dock_groups for delete to authenticated using((public.get_dock_access()->>'role') in ('Owner','Admin'));
create function dock_private.validate_group() returns trigger language plpgsql set search_path='' as $$
begin
 new.title:=btrim(new.title);
 select array_agg(distinct x order by x) into new.dock_ids from unnest(new.dock_ids)x;
 if new.dock_ids is null or exists(select 1 from unnest(new.dock_ids)x left join public.docks d on d.id=x where d.id is null or d.building<>new.building) then raise exception 'Select docks in the selected building';end if;
 if tg_op='UPDATE' then new.revision:=old.revision+1;end if;
 new.updated_at:=now();return new;
end $$;
create trigger validate_group before insert or update on public.dock_groups for each row execute function dock_private.validate_group();
create function public.save_dock_group(p_id uuid,p_title text,p_building integer,p_dock_ids uuid[],p_revision bigint default null) returns public.dock_groups language plpgsql security invoker set search_path='' as $$
declare result public.dock_groups;
begin
 if p_id is null then insert into public.dock_groups(title,building,dock_ids) values(p_title,p_building,p_dock_ids) returning * into result;
 else
 select * into result from public.dock_groups where id=p_id for update;
 if not found or result.revision is distinct from p_revision then raise exception 'This grouping changed. Reopen it before saving.';end if;
 update public.dock_groups set title=p_title,building=p_building,dock_ids=p_dock_ids where id=p_id returning * into result;
 if not found then raise exception 'Grouping permission required';end if;
 end if;
 return result;
end $$;
revoke all on function public.save_dock_group(uuid,text,integer,uuid[],bigint) from public,anon;
grant execute on function public.save_dock_group(uuid,text,integer,uuid[],bigint) to authenticated;
alter table public.docks add column move_to_group jsonb;
alter table public.dock_history add column old_move_to_group jsonb,add column new_move_to_group jsonb;
create function dock_private.validate_group_move() returns trigger language plpgsql set search_path='' as $$
declare g public.dock_groups;
begin
 if new.instruction_type is distinct from 'Move' or new.move_to_building is null then new.move_to_group:=null;end if;
 if new.move_to_group is distinct from old.move_to_group and new.move_to_group is not null then
 if current_user not in ('postgres','supabase_admin') and not dock_private.can('request_moves') then raise exception 'Move request access required' using errcode='42501';end if;
 select * into g from public.dock_groups where id=(new.move_to_group->>'id')::uuid;
 if not found or g.building<>new.move_to_building then raise exception 'Grouping is unavailable for this building';end if;
 new.move_to_group:=jsonb_build_object('id',g.id,'title',g.title,'dock_ids',g.dock_ids);
 end if;
 if new.move_to_group is not null and new.move_to_dock_number is not null and not exists(select 1 from public.docks d where d.building=new.move_to_building and d.dock_number=new.move_to_dock_number and new.move_to_group->'dock_ids' ? d.id::text) then raise exception 'Choose a destination dock in the requested grouping';end if;
 return new;
end $$;
create trigger a_group_move before update on public.docks for each row execute function dock_private.validate_group_move();
alter publication supabase_realtime add table public.dock_groups;

CREATE OR REPLACE FUNCTION dock_private.enforce_dock_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$begin
if current_user in ('postgres','supabase_admin') then return new;end if;
if new.id is distinct from old.id or (new.building,new.side,new.dock_number) is distinct from (old.building,old.side,old.dock_number) then raise exception 'Dock identity cannot be changed' using errcode='42501';end if;
if (new.status,new.custom_status_text,new.trailer_number,new.load_number,new.carrier,new.destination,new.notes,new.scheduled_departure) is distinct from (old.status,old.custom_status_text,old.trailer_number,old.load_number,old.carrier,old.destination,old.notes,old.scheduled_departure) and not dock_private.can('update_status') then raise exception 'Dock status access required' using errcode='42501';end if;
if (new.instruction_type,new.move_to_building,new.move_to_dock_number,new.move_to_group,new.move_instruction_at,new.move_timer_paused_at,new.move_timer_paused_ms) is distinct from (old.instruction_type,old.move_to_building,old.move_to_dock_number,old.move_to_group,old.move_instruction_at,old.move_timer_paused_at,old.move_timer_paused_ms) and not dock_private.can('request_moves') then raise exception 'Move request access required' using errcode='42501';end if;
if new.is_hidden is distinct from old.is_hidden and not dock_private.can('hide_docks') then raise exception 'Hide dock access required' using errcode='42501';end if;
new.updated_by:=auth.uid();new.updated_by_email:=auth.jwt()->>'email';return new;end;$function$
;
CREATE OR REPLACE FUNCTION public.touch_and_log_dock()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  new.updated_at := now();

  if old.status is not distinct from new.status
     and old.custom_status_text is not distinct from new.custom_status_text
     and old.instruction_type is not distinct from new.instruction_type
     and old.move_to_building is not distinct from new.move_to_building
     and old.move_to_dock_number is not distinct from new.move_to_dock_number
     and old.move_instruction_at is not distinct from new.move_instruction_at
     and old.move_to_group is not distinct from new.move_to_group
  then
    return new;
  end if;

  insert into public.dock_history (
    dock_id,
    building,
    side,
    dock_number,
    old_status,
    new_status,
    trailer_number,
    load_number,
    changed_at,
    changed_by,
    changed_by_email,
    old_move_to_building,
    old_move_to_dock_number,
    new_move_to_building,
    new_move_to_dock_number,
    old_custom_status_text,
    new_custom_status_text,
    old_instruction_type,
    new_instruction_type,
    old_move_to_group,
    new_move_to_group
  )
  values (
    new.id,
    new.building,
    new.side,
    new.dock_number,
    old.status,
    new.status,
    new.trailer_number,
    new.load_number,
    now(),
    new.updated_by,
    new.updated_by_email,
    old.move_to_building,
    old.move_to_dock_number,
    new.move_to_building,
    new.move_to_dock_number,
    old.custom_status_text,
    new.custom_status_text,
    old.instruction_type,
    new.instruction_type,
    old.move_to_group,
    new.move_to_group
  );

  return new;
end;
$function$
;
CREATE OR REPLACE FUNCTION dock_private.respond(p_history_id bigint, p_status text, p_destination_dock_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare h public.dock_history%rowtype;s public.docks%rowtype;d public.docks%rowtype;now_at timestamptz:=now();actor_email text:=auth.jwt()->>'email';kind text;begin
if not dock_private.can('respond_moves') then raise exception 'Driver action permission required' using errcode='42501';end if;
if p_status is null or p_status not in ('On It','Done','Need Clarification') then raise exception 'Choose On It, Done, or Need Clarification';end if;
select * into h from public.dock_history where id=p_history_id for update;if not found then raise exception 'Move request not found';end if;
if h.activity_status='Done' then raise exception 'This request is already completed';end if;
select * into s from public.docks where id=h.dock_id for update;if not found then raise exception 'Source dock not found';end if;
kind:=coalesce(h.new_instruction_type,case when h.new_move_to_building is not null then 'Move' end);
if kind is null or (coalesce(s.instruction_type,case when s.move_to_building is not null then 'Move' end),s.move_to_building,s.move_to_dock_number) is distinct from (kind,h.new_move_to_building,h.new_move_to_dock_number) then raise exception 'This request is no longer active';end if;
if s.move_to_group is distinct from h.new_move_to_group then raise exception 'This grouping request is no longer active';end if;
if p_status='Done' then
if kind='Seal Check' then return dock_private.complete_seal_check(s.id);end if;
if kind='Move' and h.new_move_to_dock_number is null then
 if p_destination_dock_id is null then raise exception 'Choose a destination dock to complete this move';end if;
 select * into d from public.docks where id=p_destination_dock_id for update;
 if not found or d.id=s.id or d.building is distinct from h.new_move_to_building or d.status<>'Open Dock' or d.is_hidden then raise exception 'Choose an open destination dock in the requested building';end if;
 if h.new_move_to_group is not null and not (h.new_move_to_group->'dock_ids' ? d.id::text) then raise exception 'Choose a destination dock in the requested grouping';end if;
 update public.docks set move_to_dock_number=d.dock_number,updated_by=auth.uid(),updated_by_email=actor_email where id=s.id;
 update public.dock_history set new_move_to_dock_number=d.dock_number where id=h.id;
end if;
return dock_private.complete_move_activity(h.id);
end if;
update public.dock_history set activity_status=p_status,activity_status_changed_at=now_at,activity_status_changed_by=auth.uid(),activity_status_changed_by_email=actor_email,activity_last_at=now_at where id=h.id;
if p_status='On It' and s.move_timer_paused_at is null then update public.docks set move_timer_paused_at=now_at,updated_by=auth.uid(),updated_by_email=actor_email where id=s.id;
elsif p_status='Need Clarification' and s.move_timer_paused_at is not null then update public.docks set move_timer_paused_ms=coalesce(s.move_timer_paused_ms,0)+greatest(0,round(extract(epoch from(now_at-s.move_timer_paused_at))*1000))::bigint,move_timer_paused_at=null,updated_by=auth.uid(),updated_by_email=actor_email where id=s.id;end if;
return jsonb_build_object('status',p_status);
end;$function$
;
CREATE OR REPLACE FUNCTION dock_private.complete_move_activity(p_history_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
  v_email text := coalesce(auth.jwt() ->> 'email', '');
  v_now timestamptz := now();

  v_activity public.dock_history%rowtype;
  v_source public.docks%rowtype;
  v_destination public.docks%rowtype;
  v_destination_ids uuid[];

  v_type text;
  v_source_type text;
  v_transferred_status text;
  v_transferred_custom text;
begin
 if not dock_private.can('respond_moves') then raise exception 'Permission required: respond_moves' using errcode='42501';end if;
  if v_uid is null then
    raise exception 'Authentication required';
  end if;

  select *
  into v_activity
  from public.dock_history
  where id = p_history_id
  for update;

  if not found then
    raise exception 'Request activity % was not found', p_history_id;
  end if;

  v_type := coalesce(
    v_activity.new_instruction_type,
    case when v_activity.new_move_to_building is not null then 'Move' end
  );

  if v_activity.dock_id is null or v_type is null then
    raise exception 'Activity % is not an active request assignment', p_history_id;
  end if;

  if v_type = 'Seal Check' then
    raise exception 'Seal Check must be completed from the DONE button on the dock';
  end if;

  select *
  into v_source
  from public.docks
  where id = v_activity.dock_id
  for update;

  if not found then
    raise exception 'Source dock for activity % was not found', p_history_id;
  end if;

  v_source_type := coalesce(
    v_source.instruction_type,
    case when v_source.move_to_building is not null then 'Move' end
  );

  if v_source_type is distinct from v_type
     or v_source.move_to_building is distinct from v_activity.new_move_to_building
     or v_source.move_to_dock_number is distinct from v_activity.new_move_to_dock_number then
    raise exception 'This request is no longer the active instruction for the dock';
  end if;

  if v_source.move_to_group is distinct from v_activity.new_move_to_group then raise exception 'This grouping request is no longer active';end if;
  v_transferred_status := v_source.status;
  v_transferred_custom := v_source.custom_status_text;

  if v_type = 'Move' then
    if v_activity.new_move_to_building is null then
      raise exception 'Move request is missing a destination building';
    end if;

    if v_activity.new_move_to_dock_number is null then raise exception 'Choose a destination dock before completing this move'; end if;

    -- Specific-dock Move: transfer the source status to the destination.
    if v_activity.new_move_to_dock_number is not null then
      select array_agg(id order by id)
      into v_destination_ids
      from public.docks
      where building = v_activity.new_move_to_building
        and dock_number = v_activity.new_move_to_dock_number;

      if coalesce(cardinality(v_destination_ids), 0) = 0 then
        raise exception 'Destination Building %, Dock % was not found',
          v_activity.new_move_to_building,
          v_activity.new_move_to_dock_number;
      end if;

      if cardinality(v_destination_ids) > 1 then
        raise exception 'Destination Building %, Dock % is ambiguous',
          v_activity.new_move_to_building,
          v_activity.new_move_to_dock_number;
      end if;

      select *
      into v_destination
      from public.docks
      where id = v_destination_ids[1]
      for update;

      if v_destination.id = v_source.id then
        raise exception 'Source and destination dock cannot be the same';
      end if;

      update public.docks
      set
        status = v_transferred_status,
        trailer_number = v_source.trailer_number,
        custom_status_text = case
          when v_transferred_status = 'Custom' then v_transferred_custom
          else null
        end,
        updated_by = v_uid,
        updated_by_email = v_email
      where id = v_destination.id;
    end if;

    -- Corrected workflow: the trailer left the source dock, so it becomes OPEN.
    update public.docks
    set
      status = 'Open Dock',
      trailer_number = null,
      custom_status_text = null,
      instruction_type = null,
      move_to_building = null,
      move_to_dock_number = null,
      move_instruction_at = null,
      move_timer_paused_at = null,
      move_timer_paused_ms = 0,
      updated_by = v_uid,
      updated_by_email = v_email
    where id = v_source.id;

  elsif v_type = 'Adjust' then
    -- Adjust completes at the same dock; retain the dock's trailer status.
    update public.docks
    set
      instruction_type = null,
      move_to_building = null,
      move_to_dock_number = null,
      move_instruction_at = null,
      move_timer_paused_at = null,
      move_timer_paused_ms = 0,
      updated_by = v_uid,
      updated_by_email = v_email
    where id = v_source.id;

  else
    raise exception 'Unsupported request type: %', v_type;
  end if;

  update public.dock_history
  set
    activity_status = 'Done',
    activity_status_changed_at = v_now,
    activity_status_changed_by = v_uid,
    activity_status_changed_by_email = v_email,
    activity_last_at = v_now
  where id = p_history_id;

  return jsonb_build_object(
    'request_type', v_type,
    'source_dock_id', v_source.id,
    'source_new_status', case when v_type = 'Move' then 'Open Dock' else v_source.status end,
    'destination_dock_id', case
      when v_type = 'Move' and v_activity.new_move_to_dock_number is not null then v_destination.id
      else null
    end,
    'transferred_status', case when v_type = 'Move' then v_transferred_status else null end
  );
end;
$function$
;
