
create schema if not exists edit_private;
revoke all on schema edit_private from public;
grant usage on schema edit_private to authenticated,service_role;
create table if not exists public.edit_attempts(
 id bigint generated always as identity primary key, request_id uuid not null default gen_random_uuid(),
 table_name text not null,record_id uuid not null,actor_id uuid,actor_name text not null,
 attempted_at timestamptz not null default clock_timestamp(),outcome text not null,
 operation text not null,expected_revision bigint,current_revision bigint,requested jsonb,current_record jsonb,reason text
);
alter table public.edit_attempts enable row level security;
revoke all on public.edit_attempts from anon,authenticated;
grant select on public.edit_attempts to authenticated;
create index if not exists edit_attempts_time_idx on public.edit_attempts(attempted_at desc,id desc);
create index if not exists edit_attempts_record_idx on public.edit_attempts(table_name,record_id,id desc);
create or replace function edit_private.record_attempt(p_table text,p_id uuid,p_outcome text,p_operation text,p_expected bigint,p_current bigint,p_requested jsonb,p_record jsonb,p_reason text default null)
returns void language plpgsql security definer set search_path='' as $fn$
declare actor text;
begin
 actor:=coalesce(nullif(auth.jwt()->>'email',''),'System / SMS');
 insert into public.edit_attempts(table_name,record_id,actor_id,actor_name,outcome,operation,expected_revision,current_revision,requested,current_record,reason)
 values(p_table,p_id,auth.uid(),split_part(actor,'@',1),p_outcome,p_operation,p_expected,p_current,p_requested,p_record,p_reason);
end $fn$;
revoke all on function edit_private.record_attempt(text,uuid,text,text,bigint,bigint,jsonb,jsonb,text) from public,anon;
grant execute on function edit_private.record_attempt(text,uuid,text,text,bigint,bigint,jsonb,jsonb,text) to authenticated,service_role;
create or replace function edit_private.bump_revision() returns trigger language plpgsql set search_path='' as $fn$
begin new.edit_revision:=old.edit_revision+1;return new;end $fn$;
revoke all on function edit_private.bump_revision() from public;
create or replace function edit_private.audit_applied() returns trigger language plpgsql security definer set search_path='' as $fn$
declare before_row jsonb;after_row jsonb;patch jsonb;rid uuid;
begin
 before_row:=case when tg_op='INSERT' then '{}'::jsonb else to_jsonb(old) end;
 after_row:=case when tg_op='DELETE' then '{}'::jsonb else to_jsonb(new) end;
 rid:=coalesce((after_row->>'id')::uuid,(before_row->>'id')::uuid);
 select coalesce(jsonb_object_agg(key,value),'{}') into patch from jsonb_each(after_row)
 where value is distinct from before_row->key and key not in ('edit_revision','updated_at','updated_by','updated_by_email');
 perform edit_private.record_attempt(tg_table_name,rid,'applied',lower(tg_op),(before_row->>'edit_revision')::bigint,(after_row->>'edit_revision')::bigint,patch,after_row,null);
 if tg_op='DELETE' then return old;end if;return new;
end $fn$;
revoke all on function edit_private.audit_applied() from public;
drop policy if exists "Read edit history" on public.edit_attempts;create policy "Read edit history" on public.edit_attempts for select to authenticated using (dock_private.can('view_board'));
alter table public.docks add column if not exists edit_revision bigint not null default 0;
create trigger zz_edit_revision before update on public.docks for each row execute function edit_private.bump_revision();
create trigger zz_edit_audit after insert or update or delete on public.docks for each row execute function edit_private.audit_applied();

create or replace function public.guarded_edit(p_table text,p_ids uuid[],p_expected jsonb,p_patch jsonb default '{}'::jsonb,p_operation text default 'update')
returns jsonb language plpgsql security invoker set search_path='' as $fn$
declare rid uuid; row_json jsonb; snapshots jsonb:='{}'; results jsonb:='[]'; cols text; conflict boolean:=false; reason text; rev bigint;
begin
 if auth.uid() is null then raise exception 'Sign in required' using errcode='42501';end if;
 if p_table not in ('docks') or p_operation not in ('update','delete') or coalesce(cardinality(p_ids),0) not between 1 and 100 then raise exception 'Invalid edit request';end if;
 for rid in select distinct x from unnest(p_ids) x order by x loop
  execute format('select to_jsonb(t) from public.%I t where id=$1 for update',p_table) into row_json using rid;
  if row_json is null then raise exception 'Record unavailable or permission denied' using errcode='42501';end if;
  snapshots:=jsonb_set(snapshots,array[rid::text],row_json);
  if not (p_expected ? rid::text) or (p_expected->>rid::text)::bigint is distinct from (row_json->>'edit_revision')::bigint then conflict:=true;end if;
 end loop;
 if conflict then
  for rid in select distinct x from unnest(p_ids) x loop
   row_json:=snapshots->rid::text;
   perform edit_private.record_attempt(p_table,rid,'conflict',p_operation,(p_expected->>rid::text)::bigint,(row_json->>'edit_revision')::bigint,p_patch,row_json,'Record changed after it was opened; no changes applied.');
  end loop;
  return jsonb_build_object('ok',false,'conflict',true,'current',snapshots,'message','Another user changed this record after you opened it. Your attempt was recorded. Review the latest version before applying your changes.');
 end if;
 begin
  if p_operation='update' then
   if jsonb_typeof(p_patch)<>'object' or p_patch='{}'::jsonb then raise exception 'Empty edit';end if;
   if exists(select 1 from jsonb_object_keys(p_patch) k where k in ('id','created_at','created_by','created_by_name','move_number','edit_revision') or not exists(select 1 from information_schema.columns c where c.table_schema='public' and c.table_name=p_table and c.column_name=k)) then raise exception 'Protected or unknown field';end if;
   select string_agg(format('%I=(jsonb_populate_record(null::public.%I,$1)).%I',k,p_table,k),',') into cols from jsonb_object_keys(p_patch) k;
  end if;
  for rid in select distinct x from unnest(p_ids) x order by x loop
   if p_operation='delete' then execute format('delete from public.%I where id=$1 returning to_jsonb(%I.*)',p_table,p_table) into row_json using rid;
   else execute format('update public.%I set %s where id=$2 returning to_jsonb(%I.*)',p_table,cols,p_table) into row_json using p_patch,rid;end if;
   if row_json is null then raise exception 'Edit permission denied' using errcode='42501';end if;
   results:=results||jsonb_build_array(row_json);
  end loop;
 exception when others then
  reason:=sqlerrm;
  for rid in select distinct x from unnest(p_ids) x loop
   row_json:=snapshots->rid::text;
   perform edit_private.record_attempt(p_table,rid,'rejected',p_operation,(p_expected->>rid::text)::bigint,(row_json->>'edit_revision')::bigint,p_patch,row_json,reason);
  end loop;
  return jsonb_build_object('ok',false,'message',reason);
 end;
 return jsonb_build_object('ok',true,'rows',results);
end $fn$;
revoke all on function public.guarded_edit(text,uuid[],jsonb,jsonb,text) from public,anon;
grant execute on function public.guarded_edit(text,uuid[],jsonb,jsonb,text) to authenticated;

create or replace function public.guarded_dock_action(p_action text,p_args jsonb,p_expected jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $fn$
declare ids uuid[];rid uuid;current_row jsonb;snapshots jsonb:='{}';result jsonb;result_rows jsonb;h public.dock_history%rowtype;conflict boolean:=false;reason text;
begin
 if auth.uid() is null then raise exception 'Sign in required' using errcode='42501';end if;
 if p_action not in ('set_docks_hidden','assign_dock_trailer','release_dock_trailer','complete_seal_check','respond_dock_activity','save_dock_details') then raise exception 'Invalid dock action';end if;
 -- Match the existing trailer-assignment lock order.
 if p_action in ('assign_dock_trailer','release_dock_trailer') then perform pg_advisory_xact_lock(7130132026);end if;
 if p_action='set_docks_hidden' then select array_agg(value::uuid) into ids from jsonb_array_elements_text(p_args->'p_dock_ids');
 elsif p_action='save_dock_details' then ids:=array[(p_args->>'p_id')::uuid];
 elsif p_action='respond_dock_activity' then
  select * into h from public.dock_history where id=(p_args->>'p_history_id')::bigint;
  if not found then raise exception 'Activity unavailable';end if;
  ids:=array[h.dock_id];
  if p_args->>'p_destination_dock_id' is not null then ids:=array_append(ids,(p_args->>'p_destination_dock_id')::uuid);
  elsif h.new_move_to_building is not null and h.new_move_to_dock_number is not null then
   select array_append(ids,id) into ids from public.docks where building=h.new_move_to_building and dock_number=h.new_move_to_dock_number limit 1;
  end if;
 else
  ids:=array[(p_args->>'p_dock_id')::uuid];
  if p_action='assign_dock_trailer' then
   select ids||coalesce(array_agg(id),'{}'::uuid[]) into ids from public.docks where trailer_number=p_args->>'p_trailer_number';
  end if;
 end if;
 if coalesce(cardinality(ids),0) not between 1 and 100 then raise exception 'No docks selected';end if;
 for rid in select distinct x from unnest(ids) x where x is not null order by x loop
  select to_jsonb(d) into current_row from public.docks d where id=rid for update;
  if current_row is null then raise exception 'Dock unavailable or permission denied' using errcode='42501';end if;
  snapshots:=jsonb_set(snapshots,array[rid::text],current_row);
  if not (p_expected ? rid::text) or (p_expected->>rid::text)::bigint is distinct from (current_row->>'edit_revision')::bigint then conflict:=true;end if;
 end loop;
 if conflict then
  for rid in select distinct x from unnest(ids) x where x is not null loop
   current_row:=snapshots->rid::text;
   perform edit_private.record_attempt('docks',rid,'conflict',p_action,(p_expected->>rid::text)::bigint,(current_row->>'edit_revision')::bigint,p_args,current_row,'Dock changed after it was opened; action not applied.');
  end loop;
  return jsonb_build_object('ok',false,'conflict',true,'current',snapshots,'message','Another user changed this dock. Your attempt was recorded. Review the latest version before trying again.');
 end if;
 begin
  case p_action
  when 'set_docks_hidden' then select coalesce(jsonb_agg(to_jsonb(d)),'[]') into result from public.set_docks_hidden(ids,(p_args->>'p_hidden')::boolean) d;
  when 'save_dock_details' then select to_jsonb(d) into result from public.save_dock_details((p_args->>'p_id')::uuid,p_args->>'p_notes',(p_args->>'p_is_hidden')::boolean,(p_args->>'p_expected_updated_at')::timestamptz) d;
  when 'assign_dock_trailer' then perform public.assign_dock_trailer((p_args->>'p_dock_id')::uuid,p_args->>'p_trailer_number');
  when 'release_dock_trailer' then perform public.release_dock_trailer((p_args->>'p_dock_id')::uuid,p_args->>'p_expected_trailer_number');
  when 'complete_seal_check' then result:=public.complete_seal_check((p_args->>'p_dock_id')::uuid);
  when 'respond_dock_activity' then result:=public.respond_dock_activity((p_args->>'p_history_id')::bigint,p_args->>'p_status',(p_args->>'p_destination_dock_id')::uuid);
  end case;
 exception when others then
  reason:=sqlerrm;
  for rid in select distinct x from unnest(ids) x where x is not null loop
   current_row:=snapshots->rid::text;
   perform edit_private.record_attempt('docks',rid,'rejected',p_action,(p_expected->>rid::text)::bigint,(current_row->>'edit_revision')::bigint,p_args,current_row,reason);
  end loop;
  return jsonb_build_object('ok',false,'message',reason);
 end;
 select coalesce(jsonb_agg(to_jsonb(d)),'[]') into result_rows from public.docks d where id=any(ids);
 return jsonb_build_object('ok',true,'result',result,'rows',result_rows);
end $fn$;
revoke all on function public.guarded_dock_action(text,jsonb,jsonb) from public,anon;
grant execute on function public.guarded_dock_action(text,jsonb,jsonb) to authenticated;
