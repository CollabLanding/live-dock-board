create schema dock_private;
revoke all on schema dock_private from public,anon;grant usage on schema dock_private to authenticated;
create table dock_private.user_access(user_id uuid primary key references auth.users(id) on delete cascade,role text not null check(role in ('Owner','Admin','User','Driver')),updated_at timestamptz not null default now(),updated_by uuid);
create table dock_private.role_permissions(role text primary key check(role in ('Admin','User','Driver')),permissions jsonb not null);
create table dock_private.permission_config(singleton boolean primary key default true check(singleton),revision int not null default 1,catalog jsonb not null);
alter table dock_private.user_access enable row level security;alter table dock_private.role_permissions enable row level security;alter table dock_private.permission_config enable row level security;
revoke all on all tables in schema dock_private from public,anon,authenticated;
insert into dock_private.user_access(user_id,role) select id,case when lower(email)='psaverchenko@collectfanatics.com' then 'Owner' else 'User' end from auth.users;
insert into dock_private.permission_config(singleton,catalog) values(true,'[{"key":"view_board","label":"View docks and trailer board","dependencies":[],"adminOnly":false,"fixed":false},{"key":"view_activity","label":"View and search Recent Activity","dependencies":["view_board"],"adminOnly":false,"fixed":false},{"key":"update_status","label":"Change dock statuses and trailer details","dependencies":["view_board"],"adminOnly":false,"fixed":false},{"key":"request_moves","label":"Request, adjust, or clear moves and seal checks","dependencies":["view_board"],"adminOnly":false,"fixed":false},{"key":"hide_docks","label":"Hide and unhide docks","dependencies":["view_board"],"adminOnly":false,"fixed":false},{"key":"batch_updates","label":"Select and update multiple docks","dependencies":["view_board"],"adminOnly":false,"fixed":false},{"key":"respond_moves","label":"On It, Done, Need Clarification, and complete seal checks","dependencies":["view_board","view_activity"],"adminOnly":false,"fixed":false},{"key":"chat","label":"Read and send Team Chat messages","dependencies":[],"adminOnly":false,"fixed":false},{"key":"clear_chat","label":"Clear Team Chat","dependencies":["chat"],"adminOnly":false,"fixed":false},{"key":"active_users","label":"View Active Users","dependencies":[],"adminOnly":false,"fixed":false},{"key":"theme","label":"Switch light and dark theme","dependencies":[],"adminOnly":false,"fixed":false},{"key":"sounds","label":"Control sounds and volume","dependencies":[],"adminOnly":false,"fixed":false},{"key":"transfers_link","label":"Show Transfers link","dependencies":[],"adminOnly":false,"fixed":false},{"key":"manage_users","label":"Manage user roles","dependencies":[],"adminOnly":true,"fixed":false},{"key":"view_permissions","label":"View and edit the Permissions grid","dependencies":[],"adminOnly":true,"fixed":false},{"key":"sign_out","label":"Sign out","dependencies":[],"adminOnly":false,"fixed":true}]');
insert into dock_private.role_permissions values('Admin','{"view_board":true,"view_activity":true,"update_status":true,"request_moves":true,"hide_docks":true,"batch_updates":true,"respond_moves":true,"chat":true,"clear_chat":true,"active_users":true,"theme":true,"sounds":true,"transfers_link":true,"manage_users":true,"view_permissions":true,"sign_out":true}');
insert into dock_private.role_permissions values('User','{"view_board":true,"view_activity":true,"update_status":true,"request_moves":true,"hide_docks":true,"batch_updates":true,"respond_moves":true,"chat":true,"clear_chat":false,"active_users":true,"theme":true,"sounds":true,"transfers_link":true,"manage_users":false,"view_permissions":false,"sign_out":true}');
insert into dock_private.role_permissions values('Driver','{"view_board":true,"view_activity":true,"update_status":false,"request_moves":false,"hide_docks":false,"batch_updates":false,"respond_moves":true,"chat":true,"clear_chat":false,"active_users":true,"theme":true,"sounds":true,"transfers_link":false,"manage_users":false,"view_permissions":false,"sign_out":true}');
create function dock_private.role() returns text language sql stable security definer set search_path='' as $$select coalesce((select role from dock_private.user_access where user_id=auth.uid()),'Driver');$$;
create function dock_private.can(p_key text) returns boolean language sql stable security definer set search_path='' as $$select auth.uid() is not null and exists(select 1 from dock_private.permission_config,jsonb_array_elements(catalog) f where f->>'key'=p_key) and (dock_private.role()='Owner' or coalesce((select (permissions->>p_key)::boolean from dock_private.role_permissions where role=dock_private.role()),false));$$;
create function dock_private.seed_user() returns trigger language plpgsql security definer set search_path='' as $$begin insert into dock_private.user_access(user_id,role) values(new.id,'Driver');return new;end;$$;
create trigger seed_dock_access after insert on auth.users for each row execute function dock_private.seed_user();
create function dock_private.access() returns jsonb language sql stable security definer set search_path='' as $$select jsonb_build_object('role',dock_private.role(),'permissions',(select jsonb_object_agg(f->>'key',dock_private.can(f->>'key')) from dock_private.permission_config,jsonb_array_elements(catalog) f),'revision',(select revision from dock_private.permission_config where singleton=true)) where auth.uid() is not null;$$;
create function public.get_dock_access() returns jsonb language sql stable security invoker set search_path='' as $$select dock_private.access();$$;
create function dock_private.read_permissions() returns jsonb language plpgsql stable security definer set search_path='' as $$begin if dock_private.role() not in ('Owner','Admin') or not dock_private.can('view_permissions') then raise exception 'Admin access required' using errcode='42501';end if;return jsonb_build_object('catalog',(select catalog from dock_private.permission_config where singleton=true),'revision',(select revision from dock_private.permission_config where singleton=true),'roles',(select jsonb_object_agg(role,permissions) from dock_private.role_permissions));end;$$;
create function public.get_dock_role_permissions() returns jsonb language sql stable security invoker set search_path='' as $$select dock_private.read_permissions();$$;
create function dock_private.save_permissions(p_roles jsonb,p_revision int) returns void language plpgsql security definer set search_path='' as $$
declare actor text:=dock_private.role();v int;r text;f jsonb;d text;begin
if auth.uid() is null or actor not in ('Owner','Admin') or not dock_private.can('view_permissions') then raise exception 'Admin access required' using errcode='42501';end if;
select revision into v from dock_private.permission_config where singleton=true for update;
if v is distinct from p_revision then raise exception 'Permissions changed. Close and reopen the grid before saving.';end if;
if jsonb_typeof(p_roles) is distinct from 'object' or (select count(*) from jsonb_object_keys(p_roles))<>3 then raise exception 'Provide Admin, User, and Driver permissions';end if;
if actor='Admin' and p_roles->'Admin' is distinct from (select permissions from dock_private.role_permissions where role='Admin') then raise exception 'Only the Owner can change Admin permissions' using errcode='42501';end if;
foreach r in array array['Admin','User','Driver'] loop
if jsonb_typeof(p_roles->r) is distinct from 'object' or (select count(*) from jsonb_object_keys(p_roles->r))<>(select jsonb_array_length(catalog) from dock_private.permission_config where singleton=true) then raise exception 'Invalid role permissions';end if;
for f in select value from dock_private.permission_config,jsonb_array_elements(catalog) loop
if jsonb_typeof(p_roles->r->(f->>'key')) is distinct from 'boolean' then raise exception 'Every permission must be checked or unchecked';end if;
if (p_roles->r->>(f->>'key'))::boolean then
if (f->>'adminOnly')::boolean and r<>'Admin' then raise exception 'User administration requires Admin role';end if;
for d in select jsonb_array_elements_text(f->'dependencies') loop if not (p_roles->r->>d)::boolean then raise exception 'Permission % requires %',f->>'key',d;end if;end loop;
elsif (f->>'fixed')::boolean then raise exception 'Sign out must remain available';end if;
end loop;
if actor='Owner' or r<>'Admin' then update dock_private.role_permissions set permissions=p_roles->r where role=r;end if;
end loop;
update dock_private.permission_config set revision=revision+1 where singleton=true;end;$$;
create function public.save_dock_role_permissions(p_roles jsonb,p_revision int) returns void language sql security invoker set search_path='' as $$select dock_private.save_permissions(p_roles,p_revision);$$;
create function dock_private.list_users() returns table(id uuid,email text,role text) language plpgsql stable security definer set search_path='' as $$begin if dock_private.role() not in ('Owner','Admin') or not dock_private.can('manage_users') then raise exception 'Admin access required' using errcode='42501';end if;return query select u.id,u.email::text,a.role from auth.users u join dock_private.user_access a on a.user_id=u.id order by lower(u.email);end;$$;
create function public.list_dock_users() returns table(id uuid,email text,role text) language sql stable security invoker set search_path='' as $$select * from dock_private.list_users();$$;
create function dock_private.set_role(p_user_id uuid,p_role text) returns void language plpgsql security definer set search_path='' as $$begin
if dock_private.role() not in ('Owner','Admin') or not dock_private.can('manage_users') then raise exception 'Admin access required' using errcode='42501';end if;
if p_role is null or p_role not in ('Admin','User','Driver') then raise exception 'Choose Admin, User, or Driver';end if;
if p_user_id=auth.uid() then raise exception 'You cannot change your own role';end if;
perform 1 from dock_private.user_access where user_id=p_user_id and role<>'Owner' for update;if not found then raise exception 'Owner access is protected or user was not found';end if;
update dock_private.user_access set role=p_role,updated_at=now(),updated_by=auth.uid() where user_id=p_user_id;end;$$;
create function public.set_dock_user_role(p_user_id uuid,p_role text) returns void language sql security invoker set search_path='' as $$select dock_private.set_role(p_user_id,p_role);$$;
revoke all on all functions in schema dock_private from public,anon,authenticated;
grant execute on function dock_private.role(),dock_private.can(text),dock_private.access(),dock_private.read_permissions(),dock_private.save_permissions(jsonb,int),dock_private.list_users(),dock_private.set_role(uuid,text) to authenticated;
revoke all on function public.get_dock_access(),public.get_dock_role_permissions(),public.save_dock_role_permissions(jsonb,int),public.list_dock_users(),public.set_dock_user_role(uuid,text) from public,anon;grant execute on function public.get_dock_access(),public.get_dock_role_permissions(),public.save_dock_role_permissions(jsonb,int),public.list_dock_users(),public.set_dock_user_role(uuid,text) to authenticated;
create policy "Dock permission read" on public.docks as restrictive for select to authenticated using(dock_private.can('view_board'));
create policy "Dock permission update" on public.docks as restrictive for update to authenticated using(dock_private.can('update_status') or dock_private.can('request_moves') or dock_private.can('hide_docks')) with check(dock_private.can('update_status') or dock_private.can('request_moves') or dock_private.can('hide_docks'));
create policy "Activity permission read" on public.dock_history as restrictive for select to authenticated using(dock_private.can('view_activity'));
create policy "Activity RPC only" on public.dock_history as restrictive for update to authenticated using(false) with check(false);
create policy "Chat permission read" on public.chat_messages as restrictive for select to authenticated using(dock_private.can('chat'));
create policy "Chat permission send" on public.chat_messages as restrictive for insert to authenticated with check(dock_private.can('chat') and (message<>'__LIVE_TRAILER_BOARD_CLEAR_CHAT_V1__' or dock_private.can('clear_chat')));
create policy "Chat permission clear" on public.chat_messages for delete to authenticated using(dock_private.can('clear_chat'));
create function dock_private.enforce_dock_update() returns trigger language plpgsql security invoker set search_path='' as $$begin
if current_user in ('postgres','supabase_admin') then return new;end if;
if new.id is distinct from old.id or (new.building,new.side,new.dock_number) is distinct from (old.building,old.side,old.dock_number) then raise exception 'Dock identity cannot be changed' using errcode='42501';end if;
if (new.status,new.custom_status_text,new.trailer_number,new.load_number,new.carrier,new.destination,new.notes,new.scheduled_departure) is distinct from (old.status,old.custom_status_text,old.trailer_number,old.load_number,old.carrier,old.destination,old.notes,old.scheduled_departure) and not dock_private.can('update_status') then raise exception 'Dock status access required' using errcode='42501';end if;
if (new.instruction_type,new.move_to_building,new.move_to_dock_number,new.move_instruction_at,new.move_timer_paused_at,new.move_timer_paused_ms) is distinct from (old.instruction_type,old.move_to_building,old.move_to_dock_number,old.move_instruction_at,old.move_timer_paused_at,old.move_timer_paused_ms) and not dock_private.can('request_moves') then raise exception 'Move request access required' using errcode='42501';end if;
if new.is_hidden is distinct from old.is_hidden and not dock_private.can('hide_docks') then raise exception 'Hide dock access required' using errcode='42501';end if;
new.updated_by:=auth.uid();new.updated_by_email:=auth.jwt()->>'email';return new;end;$$;
revoke all on function dock_private.enforce_dock_update() from public,anon,authenticated;
create trigger enforce_dock_update before update on public.docks for each row execute function dock_private.enforce_dock_update();
CREATE OR REPLACE FUNCTION dock_private.set_docks_hidden(p_dock_ids uuid[], p_hidden boolean)
 RETURNS SETOF public.docks
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
  v_email text := coalesce(auth.jwt() ->> 'email', '');
begin
 if not dock_private.can('hide_docks') then raise exception 'Permission required: hide_docks' using errcode='42501';end if;
 if cardinality(p_dock_ids)>1 and not dock_private.can('batch_updates') then raise exception 'Batch access required' using errcode='42501';end if;
  if v_uid is null then
    raise exception 'Authentication required';
  end if;

  if p_dock_ids is null or cardinality(p_dock_ids) = 0 then
    return;
  end if;

  return query
  update public.docks as d
  set
    is_hidden = coalesce(p_hidden, false),
    updated_by = v_uid,
    updated_by_email = v_email
  where d.id = any(p_dock_ids)
  returning d.*;
end;
$function$;
create or replace function public.set_docks_hidden(p_dock_ids uuid[],p_hidden boolean) returns setof public.docks language sql security invoker set search_path='' as $$select * from dock_private.set_docks_hidden(p_dock_ids,p_hidden);$$;
revoke all on function dock_private.set_docks_hidden(uuid[],boolean),public.set_docks_hidden(uuid[],boolean) from public,anon;grant execute on function dock_private.set_docks_hidden(uuid[],boolean),public.set_docks_hidden(uuid[],boolean) to authenticated;
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

  v_transferred_status := v_source.status;
  v_transferred_custom := v_source.custom_status_text;

  if v_type = 'Move' then
    if v_activity.new_move_to_building is null then
      raise exception 'Move request is missing a destination building';
    end if;

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
$function$;
create or replace function public.complete_move_activity(p_history_id bigint) returns jsonb language sql security invoker set search_path='' as $$select dock_private.complete_move_activity(p_history_id);$$;
revoke all on function dock_private.complete_move_activity(bigint),public.complete_move_activity(bigint) from public,anon;grant execute on function dock_private.complete_move_activity(bigint),public.complete_move_activity(bigint) to authenticated;
CREATE OR REPLACE FUNCTION dock_private.complete_seal_check(p_dock_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
  v_email text := coalesce(auth.jwt() ->> 'email', '');
  v_now timestamptz := now();

  v_dock public.docks%rowtype;
  v_history_id public.dock_history.id%type;
begin
 if not dock_private.can('respond_moves') then raise exception 'Permission required: respond_moves' using errcode='42501';end if;
  if v_uid is null then
    raise exception 'Authentication required';
  end if;

  select *
  into v_dock
  from public.docks
  where id = p_dock_id
  for update;

  if not found then
    raise exception 'Dock % was not found', p_dock_id;
  end if;

  if v_dock.instruction_type is distinct from 'Seal Check'
     or v_dock.move_instruction_at is null then
    raise exception 'This dock does not have an active Seal Check';
  end if;

  select h.id
  into v_history_id
  from public.dock_history h
  where h.dock_id = p_dock_id
    and h.new_instruction_type = 'Seal Check'
    and h.activity_status is null
  order by h.changed_at desc, h.id desc
  limit 1
  for update;

  if v_history_id is null then
    raise exception 'Seal Check activity could not be found';
  end if;

  -- Complete the Seal Check:
  -- dock becomes Loaded and the request/timer clears.
  update public.docks
  set
    status = 'Loaded',
    custom_status_text = null,
    instruction_type = null,
    move_to_building = null,
    move_to_dock_number = null,
    move_instruction_at = null,
    move_timer_paused_at = null,
    move_timer_paused_ms = 0,
    updated_by = v_uid,
    updated_by_email = v_email
  where id = p_dock_id;

  update public.dock_history
  set
    activity_status = 'Done',
    activity_status_changed_at = v_now,
    activity_status_changed_by = v_uid,
    activity_status_changed_by_email = v_email,
    activity_last_at = v_now
  where id = v_history_id;

  return jsonb_build_object(
    'dock_id', p_dock_id,
    'history_id', v_history_id,
    'status', 'Loaded'
  );
end;
$function$;
create or replace function public.complete_seal_check(p_dock_id uuid) returns jsonb language sql security invoker set search_path='' as $$select dock_private.complete_seal_check(p_dock_id);$$;
revoke all on function dock_private.complete_seal_check(uuid),public.complete_seal_check(uuid) from public,anon;grant execute on function dock_private.complete_seal_check(uuid),public.complete_seal_check(uuid) to authenticated;
drop function public.bump_expired_move_activity(bigint,timestamptz,integer,integer,text);
CREATE OR REPLACE FUNCTION dock_private.bump_expired_move_activity(p_dock_id uuid, p_move_instruction_at timestamp with time zone, p_move_to_building integer, p_move_to_dock_number integer, p_instruction_type text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_history_id bigint;
begin
 if not dock_private.can('view_board') then raise exception 'Permission required: view_board' using errcode='42501';end if;
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if p_instruction_type not in ('Move','Adjust','Seal Check') then
    return null;
  end if;

  if not exists (
    select 1
    from public.docks d
    where d.id = p_dock_id
      and d.instruction_type is not distinct from p_instruction_type
      and d.move_instruction_at is not distinct from p_move_instruction_at
      and d.move_to_building is not distinct from p_move_to_building
      and d.move_to_dock_number is not distinct from p_move_to_dock_number
      and d.move_timer_paused_at is null
      and now() >= (
        d.move_instruction_at
        + interval '10 minutes'
        + (coalesce(d.move_timer_paused_ms,0) * interval '1 millisecond')
      )
  ) then
    return null;
  end if;

  select h.id
  into v_history_id
  from public.dock_history h
  where h.dock_id = p_dock_id
    and h.new_instruction_type is not distinct from p_instruction_type
    and h.new_move_to_building is not distinct from p_move_to_building
    and h.new_move_to_dock_number is not distinct from p_move_to_dock_number
    and h.activity_status is null
  order by h.changed_at desc, h.id desc
  limit 1
  for update;

  if v_history_id is null then
    return null;
  end if;

  update public.dock_history h
  set activity_last_at = now()
  where h.id = v_history_id
    and h.activity_status is null
    and coalesce(h.activity_last_at,h.changed_at) <= (
      p_move_instruction_at + interval '10 minutes'
    )
  returning h.id into v_history_id;

  return v_history_id;
end;
$function$;
create or replace function public.bump_expired_move_activity(p_dock_id uuid,p_move_instruction_at timestamptz,p_move_to_building integer,p_move_to_dock_number integer,p_instruction_type text) returns bigint language sql security invoker set search_path='' as $$select dock_private.bump_expired_move_activity(p_dock_id,p_move_instruction_at,p_move_to_building,p_move_to_dock_number,p_instruction_type);$$;
revoke all on function dock_private.bump_expired_move_activity(uuid,timestamptz,integer,integer,text),public.bump_expired_move_activity(uuid,timestamptz,integer,integer,text) from public,anon;grant execute on function dock_private.bump_expired_move_activity(uuid,timestamptz,integer,integer,text),public.bump_expired_move_activity(uuid,timestamptz,integer,integer,text) to authenticated;

create function dock_private.respond(p_history_id bigint,p_status text,p_destination_dock_id uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare h public.dock_history%rowtype;s public.docks%rowtype;d public.docks%rowtype;now_at timestamptz:=now();actor_email text:=auth.jwt()->>'email';kind text;begin
if not dock_private.can('respond_moves') then raise exception 'Driver action permission required' using errcode='42501';end if;
if p_status is null or p_status not in ('On It','Done','Need Clarification') then raise exception 'Choose On It, Done, or Need Clarification';end if;
select * into h from public.dock_history where id=p_history_id for update;if not found then raise exception 'Move request not found';end if;
if h.activity_status='Done' then raise exception 'This request is already completed';end if;
select * into s from public.docks where id=h.dock_id for update;if not found then raise exception 'Source dock not found';end if;
kind:=coalesce(h.new_instruction_type,case when h.new_move_to_building is not null then 'Move' end);
if kind is null or (coalesce(s.instruction_type,case when s.move_to_building is not null then 'Move' end),s.move_to_building,s.move_to_dock_number) is distinct from (kind,h.new_move_to_building,h.new_move_to_dock_number) then raise exception 'This request is no longer active';end if;
if p_status='Done' then
if kind='Seal Check' then return dock_private.complete_seal_check(s.id);end if;
if kind='Move' and h.new_move_to_dock_number is null then
 if p_destination_dock_id is null then raise exception 'Choose a destination dock to complete this move';end if;
 select * into d from public.docks where id=p_destination_dock_id for update;
 if not found or d.id=s.id or d.building is distinct from h.new_move_to_building or d.status<>'Open Dock' or d.is_hidden then raise exception 'Choose an open destination dock in the requested building';end if;
 update public.docks set move_to_dock_number=d.dock_number,updated_by=auth.uid(),updated_by_email=actor_email where id=s.id;
 update public.dock_history set new_move_to_dock_number=d.dock_number where id=h.id;
end if;
return dock_private.complete_move_activity(h.id);
end if;
update public.dock_history set activity_status=p_status,activity_status_changed_at=now_at,activity_status_changed_by=auth.uid(),activity_status_changed_by_email=actor_email,activity_last_at=now_at where id=h.id;
if p_status='On It' and s.move_timer_paused_at is null then update public.docks set move_timer_paused_at=now_at,updated_by=auth.uid(),updated_by_email=actor_email where id=s.id;
elsif p_status='Need Clarification' and s.move_timer_paused_at is not null then update public.docks set move_timer_paused_ms=coalesce(s.move_timer_paused_ms,0)+greatest(0,round(extract(epoch from(now_at-s.move_timer_paused_at))*1000))::bigint,move_timer_paused_at=null,updated_by=auth.uid(),updated_by_email=actor_email where id=s.id;end if;
return jsonb_build_object('status',p_status);
end;$$;
create function public.respond_dock_activity(p_history_id bigint,p_status text,p_destination_dock_id uuid default null) returns jsonb language sql security invoker set search_path='' as $$select dock_private.respond(p_history_id,p_status,p_destination_dock_id);$$;
revoke all on function dock_private.respond(bigint,text,uuid),public.respond_dock_activity(bigint,text,uuid) from public,anon;grant execute on function dock_private.respond(bigint,text,uuid),public.respond_dock_activity(bigint,text,uuid) to authenticated;
create function dock_private.enforce_batch() returns trigger language plpgsql security invoker set search_path='' as $$begin if current_user not in ('postgres','supabase_admin') and not dock_private.can('batch_updates') and (select count(*) from updated_docks)>1 then raise exception 'Batch update permission required' using errcode='42501';end if;return null;end;$$;
revoke all on function dock_private.enforce_batch() from public,anon,authenticated;
create trigger enforce_dock_batch after update on public.docks referencing new table as updated_docks for each statement execute function dock_private.enforce_batch();
revoke all on function public.touch_and_log_dock(),public.touch_history_activity_last_at() from public,anon,authenticated;


-- Require a destination for every completed move.
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
$function$;
