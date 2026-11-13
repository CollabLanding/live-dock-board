create schema recovery_private;
revoke all on schema recovery_private from public,anon,authenticated;
grant usage on schema recovery_private to authenticated;
create table recovery_private.tracked(table_name text primary key, pk text[] not null, priority int not null);
insert into recovery_private.tracked values ('chat_messages',array['id'],4),
('dock_groups',array['id'],3),
('docks',array['id'],1),
('trailers',array['id'],2);
create table recovery_private.events(id bigint generated always as identity primary key,table_name text not null,record_key jsonb not null,operation text not null,before_data jsonb,after_data jsonb,actor_id uuid,actor_name text not null default 'System',at timestamptz not null default clock_timestamp(),recovery_run uuid);
create index on recovery_private.events(table_name,record_key,id);
create index on recovery_private.events(at desc);
create table recovery_private.snapshots(id uuid primary key default gen_random_uuid(),at timestamptz not null default now(),label text not null,data jsonb not null,actor_id uuid);
create table recovery_private.plans(id uuid primary key default gen_random_uuid(),actor_id uuid not null,at timestamptz not null default now(),items jsonb not null,applied_at timestamptz,backup_id uuid);
create table recovery_private.blocks(user_id uuid primary key,at timestamptz not null default now(),actor_id uuid);
create table recovery_private.settings(id boolean primary key default true check(id),locked boolean not null default false,started_at timestamptz not null default now());
insert into recovery_private.settings(id) values(true);
create table recovery_private.runs(id uuid primary key,actor_id uuid not null,at timestamptz not null default now(),plan_id uuid not null,backup_id uuid not null,affected int not null);
alter table recovery_private.tracked enable row level security;
alter table recovery_private.events enable row level security;
alter table recovery_private.snapshots enable row level security;
alter table recovery_private.plans enable row level security;
alter table recovery_private.blocks enable row level security;
alter table recovery_private.settings enable row level security;
alter table recovery_private.runs enable row level security;
revoke all on all tables in schema recovery_private from public,anon,authenticated;
revoke all on all sequences in schema recovery_private from public,anon,authenticated;

create function recovery_private.is_owner() returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and exists(select 1 from dock_private.user_access where user_id=auth.uid() and role='Owner');
$$;
create function recovery_private.require_owner() returns void language plpgsql stable security definer set search_path='' as $$
begin if not recovery_private.is_owner() then raise exception 'Owner access required';end if;end $$;
create function recovery_private.row_key(p_row jsonb,p_keys text[]) returns jsonb language sql immutable set search_path='' as $$
 select jsonb_object_agg(k,p_row->k) from unnest(p_keys) k;
$$;
create function recovery_private.guard_write() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is not null and not recovery_private.is_owner() and ((select locked from recovery_private.settings where id) or exists(select 1 from recovery_private.blocks where user_id=auth.uid())) then raise exception 'Editing has been locked by the Owner';end if;
 if tg_op='DELETE' then return old;end if;return new;
end $$;
create function recovery_private.capture() returns trigger language plpgsql security definer set search_path='' as $$
declare b jsonb;a jsonb;keys text[];
begin
 b=case when tg_op='INSERT' then null else to_jsonb(old) end;a=case when tg_op='DELETE' then null else to_jsonb(new) end;
 if b is not distinct from a then return null;end if;
 select pk into strict keys from recovery_private.tracked where table_name=tg_table_name;
 insert into recovery_private.events(table_name,record_key,operation,before_data,after_data,actor_id,actor_name)
 values(tg_table_name,recovery_private.row_key(coalesce(a,b),keys),tg_op,b,a,auth.uid(),coalesce(nullif(split_part(auth.jwt()->>'email','@',1),''),'System'));
 return null;
end $$;
do $$ declare t record;begin for t in select * from recovery_private.tracked loop
 execute format('create trigger aaa_recovery_guard before insert or update or delete on public.%I for each row execute function recovery_private.guard_write()',t.table_name);
 execute format('create trigger zzz_recovery_capture after insert or update or delete on public.%I for each row execute function recovery_private.capture()',t.table_name);
 end loop;
 -- Emergency locks also protect the site's ordinary activity/chat logs.
 for t in select unnest(array['dock_history','trailer_activity']) as table_name loop
 execute format('create trigger aaa_recovery_guard before insert or update or delete on public.%I for each row execute function recovery_private.guard_write()',t.table_name);
 end loop;
end $$;
create function recovery_private.current_row(p_table text,p_key jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;keys text[];begin
 select pk into strict keys from recovery_private.tracked where table_name=p_table;
 execute format('select to_jsonb(t) from public.%I t where recovery_private.row_key(to_jsonb(t),$2)=$1',p_table) into result using p_key,keys;return result;
end $$;
create function recovery_private.take_snapshot(p_label text) returns uuid language plpgsql security definer set search_path='' as $$
declare t record;data jsonb='{}';part jsonb;result uuid;
begin
 if auth.uid() is not null then perform recovery_private.require_owner();elsif session_user not in ('postgres','supabase_admin') then raise exception 'Owner access required';end if;
 perform pg_advisory_xact_lock(89213655);
 for t in select * from recovery_private.tracked order by table_name loop execute format('lock table public.%I in share mode',t.table_name);end loop;
 -- Freeze writes while collecting a consistent snapshot of all protected tables.
 for t in select * from recovery_private.tracked order by priority,table_name loop
 execute format('select coalesce(jsonb_agg(to_jsonb(t)),''[]''::jsonb) from public.%I t',t.table_name) into part;
 data=data||jsonb_build_object(t.table_name,part);end loop;
 insert into recovery_private.snapshots(label,data,actor_id) values(left(p_label,120),data,auth.uid()) returning id into result;
 return result;
end $$;
create function recovery_private.preview(p_mode text,p_ids bigint[],p_snapshot uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare items jsonb='[]';e record;t record;k jsonb;oldest recovery_private.events;latest recovery_private.events;cur jsonb;desired jsonb;reason text;plan uuid;snapshot jsonb;source_rows jsonb;count_rows int=0;
begin
 perform recovery_private.require_owner();
 if p_mode='changes' then
 if coalesce(cardinality(p_ids),0)=0 or cardinality(p_ids)>1000 then raise exception 'Select 1–1000 history entries';end if;
 for e in select table_name,record_key,min(id) first_id,max(id) last_id from recovery_private.events where id=any(p_ids) group by table_name,record_key loop
 select * into oldest from recovery_private.events where id=e.first_id;select * into latest from recovery_private.events where id=e.last_id;
 cur=recovery_private.current_row(e.table_name,e.record_key);desired=oldest.before_data;reason=null;
 if exists(select 1 from recovery_private.events h where h.table_name=e.table_name and h.record_key=e.record_key and h.id>=e.first_id and not h.id=any(p_ids)) then reason='Later or intervening changes exist; select a different recovery range';
 elsif cur is distinct from latest.after_data then reason='Current record differs from the saved history';end if;
 if desired is not null and recovery_private.row_key(desired,(select pk from recovery_private.tracked where table_name=e.table_name)) is distinct from e.record_key then reason='Record key changed; use a backup or recover related records separately';end if;
 if cur is not distinct from desired then reason='Already matches the requested state';end if;
 items=items||jsonb_build_array(jsonb_build_object('table',e.table_name,'key',e.record_key,'current',cur,'restore',desired,'reason',reason));
 end loop;
 elsif p_mode='snapshot' then
 select data into snapshot from recovery_private.snapshots where id=p_snapshot;if snapshot is null then raise exception 'Backup not found';end if;
 for t in select * from recovery_private.tracked order by priority,table_name loop
 execute format('select coalesce(jsonb_agg(to_jsonb(x)),''[]''::jsonb) from public.%I x',t.table_name) into source_rows;
 for k in select distinct recovery_private.row_key(value,t.pk) from jsonb_array_elements(source_rows||coalesce(snapshot->t.table_name,'[]')) loop
 cur=recovery_private.current_row(t.table_name,k);select value into desired from jsonb_array_elements(coalesce(snapshot->t.table_name,'[]')) where recovery_private.row_key(value,t.pk)=k;
 if cur is distinct from desired then items=items||jsonb_build_array(jsonb_build_object('table',t.table_name,'key',k,'current',cur,'restore',desired,'reason',null));end if;
 end loop;end loop;
 else raise exception 'Unknown recovery mode';end if;
 if jsonb_array_length(items)>10000 then raise exception 'Recovery is too large. Narrow the selected records.';end if;
 insert into recovery_private.plans(actor_id,items) values(auth.uid(),items) returning id into plan;
 return jsonb_build_object('plan_id',plan,'expires_at',now()+interval '15 minutes','items',items);
end $$;
create function recovery_private.apply(p_plan uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare plan recovery_private.plans;item jsonb;k jsonb;t record;tr record;disabled jsonb='[]';cols text;sets text;cols_array text[];target jsonb;backup uuid;run uuid=gen_random_uuid();affected int=0;unplanned boolean;
begin
 perform recovery_private.require_owner();
 select * into strict plan from recovery_private.plans where id=p_plan and actor_id=auth.uid() for update;
 if plan.applied_at is not null or plan.at<now()-interval '15 minutes' then raise exception 'Preview expired or already applied. Preview again.';end if;
 -- Serialize recovery and freeze tracked tables while checking the preview.
 perform pg_advisory_xact_lock(89213655);
 for t in select * from recovery_private.tracked order by table_name loop execute format('lock table public.%I in access exclusive mode',t.table_name);end loop;
 for item in select value from jsonb_array_elements(plan.items) where value->>'reason' is null loop
 if recovery_private.current_row(item->>'table',item->'key') is distinct from nullif(item->'current','null') then raise exception 'A record changed after preview. Preview again; nothing was restored.';end if;
 end loop;
 backup=recovery_private.take_snapshot('Before recovery '||run::text);
 -- Disable ordinary triggers only inside this locked, atomic Owner recovery transaction.
 -- Foreign-key/check/unique constraints remain active. Original trigger states are preserved.
 for tr in select c.relname table_name,g.tgname,g.tgenabled from pg_trigger g join pg_class c on c.oid=g.tgrelid join recovery_private.tracked rt on rt.table_name=c.relname where c.relnamespace='public'::regnamespace and not g.tgisinternal and g.tgenabled in ('O','A') loop
 disabled=disabled||jsonb_build_array(jsonb_build_object('table',tr.table_name,'trigger',tr.tgname,'state',tr.tgenabled));
 execute format('alter table public.%I disable trigger %I',tr.table_name,tr.tgname);end loop;
 -- Parents first; metadata revisions advance so stale editor forms cannot overwrite restored data.
 for item in select x.value from jsonb_array_elements(plan.items) x join recovery_private.tracked rt on rt.table_name=x.value->>'table' where x.value->>'reason' is null and x.value->'restore'<>'null'::jsonb order by rt.priority,rt.table_name loop
 target=item->'restore';
 if target ? 'edit_revision' then target=jsonb_set(target,'{edit_revision}',to_jsonb(coalesce((item->'current'->>'edit_revision')::bigint,(target->>'edit_revision')::bigint,0)+1));end if;
 if target ? 'revision' then target=jsonb_set(target,'{revision}',to_jsonb(coalesce((item->'current'->>'revision')::bigint,(target->>'revision')::bigint,0)+1));end if;
 if target ? 'updated_at' then target=jsonb_set(target,'{updated_at}',to_jsonb(clock_timestamp()));end if;
 if target ? 'updated_by' then target=jsonb_set(target,'{updated_by}',to_jsonb(auth.uid()));end if;
 -- Resolve the self-referencing transfer link after all missing jobs have been inserted.
 if item->>'table'='transfers' and target ? 'linked_next_id' then target=jsonb_set(target,'{linked_next_id}','null');end if;
 if item->>'table'='docks' and target ? 'move_to_group' then target=jsonb_set(target,'{move_to_group}','null');end if;
 select array_agg(a.attname order by a.attnum) into cols_array from pg_attribute a where a.attrelid=format('public.%I',item->>'table')::regclass and a.attnum>0 and not a.attisdropped and a.attgenerated='' and target ? a.attname;
 select string_agg(format('%I',x),','),string_agg(format('%I=r.%I',x,x),',') into cols,sets from unnest(cols_array)x;
 if item->'current'='null'::jsonb then
 execute format('insert into public.%I(%s) overriding system value select %s from jsonb_populate_record(null::public.%I,$1) r',item->>'table',cols,cols,item->>'table') using target;
 else
 select * into strict t from recovery_private.tracked where table_name=item->>'table';
 execute format('update public.%I v set %s from jsonb_populate_record(null::public.%I,$1) r where recovery_private.row_key(to_jsonb(v),$2)=$3',item->>'table',sets,item->>'table') using target,t.pk,item->'key';
 end if;
 affected=affected+1;
 end loop;
 -- Finish deferred logical references once all referenced records exist.
 for item in select value from jsonb_array_elements(plan.items) where value->>'reason' is null and value->'restore'<>'null'::jsonb loop
 if item->>'table'='transfers' and item->'restore' ? 'linked_next_id' then execute 'update public.transfers set linked_next_id=($1->>''linked_next_id'')::uuid where id=($1->>''id'')::uuid' using item->'restore';end if;
 if item->>'table'='docks' and item->'restore' ? 'move_to_group' then execute 'update public.docks set move_to_group=$1->''move_to_group'' where id=($1->>''id'')::uuid' using item->'restore';end if;
 end loop;
 -- Children first when removing records that were created after the selected backup/change.
 for item in select x.value from jsonb_array_elements(plan.items)x join recovery_private.tracked rt on rt.table_name=x.value->>'table' where x.value->>'reason' is null and x.value->'restore'='null'::jsonb order by rt.priority desc,rt.table_name desc loop
 select * into strict t from recovery_private.tracked where table_name=item->>'table';
 execute format('delete from public.%I v where recovery_private.row_key(to_jsonb(v),$1)=$2',item->>'table') using t.pk,item->'key';affected=affected+1;
 end loop;
 for t in select * from recovery_private.tracked loop
 execute format('with old_rows as (select recovery_private.row_key(value,$1) k,value v from jsonb_array_elements($2)), new_rows as (select recovery_private.row_key(to_jsonb(x),$1) k,to_jsonb(x) v from public.%I x) select exists(select 1 from old_rows o full join new_rows n using(k) where o.v is distinct from n.v and not exists(select 1 from jsonb_array_elements($3) p where p->>''table''=$4 and p->''key''=coalesce(o.k,n.k) and p->>''reason'' is null))',t.table_name) into unplanned using t.pk,(select data->t.table_name from recovery_private.snapshots where id=backup),plan.items,t.table_name;
 if unplanned then raise exception 'Recovery would affect related records outside this preview. Include related records; nothing was restored.';end if;
 end loop;
 for tr in select * from jsonb_to_recordset(disabled) as x("table" text,"trigger" text,state text) loop
 execute format('alter table public.%I enable %s trigger %I',tr."table",case when tr.state='A' then 'always' else '' end,tr."trigger");end loop;
 for item in select value from jsonb_array_elements(plan.items) where value->>'reason' is null loop
 insert into recovery_private.events(table_name,record_key,operation,before_data,after_data,actor_id,actor_name,recovery_run)
 values(item->>'table',item->'key','RECOVERY',nullif(item->'current','null'),recovery_private.current_row(item->>'table',item->'key'),auth.uid(),coalesce(split_part(auth.jwt()->>'email','@',1),'Owner'),run);
 
 end loop;
 update recovery_private.plans set applied_at=now(),backup_id=backup where id=p_plan;
 insert into recovery_private.runs(id,actor_id,plan_id,backup_id,affected) values(run,auth.uid(),p_plan,backup,affected);
 return jsonb_build_object('affected',affected,'backup_id',backup,'run_id',run);
end $$;
create function recovery_private.status() returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;begin perform recovery_private.require_owner();
 select jsonb_build_object('started_at',(select started_at from recovery_private.settings where id),'locked',(select locked from recovery_private.settings where id),'tables',(select jsonb_agg(table_name order by priority) from recovery_private.tracked),'snapshots',(select coalesce(jsonb_agg(s),'[]') from(select id,at,label,pg_column_size(data) bytes from recovery_private.snapshots order by at desc limit 50)s),'users',(select coalesce(jsonb_agg(u),'[]') from(select a.user_id,a.role,coalesce(x.email,a.user_id::text) email,exists(select 1 from recovery_private.blocks b where b.user_id=a.user_id) blocked from dock_private.user_access a left join auth.users x on x.id=a.user_id order by x.email)u),'last_recovery',(select to_jsonb(r) from recovery_private.runs r order by at desc limit 1)) into result;return result;end $$;
create function recovery_private.list_changes(p_from timestamptz,p_to timestamptz,p_actor uuid,p_deleted boolean,p_offset int) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;begin perform recovery_private.require_owner();if p_to<p_from then raise exception 'Invalid range';end if;
 select jsonb_build_object('rows',(select coalesce(jsonb_agg(r),'[]') from(select id,table_name,record_key,operation,actor_id,actor_name,at,recovery_run,before_data,after_data from recovery_private.events where at>=p_from and at<=p_to and (p_actor is null or actor_id=p_actor) and (not p_deleted or operation='DELETE') order by id desc limit 200 offset greatest(0,p_offset))r),'count',(select count(*) from recovery_private.events where at>=p_from and at<=p_to and (p_actor is null or actor_id=p_actor) and (not p_deleted or operation='DELETE'))) into result;return result;end $$;
create function recovery_private.set_lock(p_user uuid,p_locked boolean) returns void language plpgsql security definer set search_path='' as $$
begin perform recovery_private.require_owner();
 if p_user is null then update recovery_private.settings set locked=p_locked where id;
 else
 if exists(select 1 from dock_private.user_access where user_id=p_user and role='Owner') then raise exception 'Owner accounts cannot be locked';end if;
 if p_locked then insert into recovery_private.blocks(user_id,actor_id) values(p_user,auth.uid()) on conflict(user_id) do update set at=now(),actor_id=auth.uid();else delete from recovery_private.blocks where user_id=p_user;end if;
 end if;
end $$;
create function recovery_private.download(p_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;begin perform recovery_private.require_owner();select jsonb_build_object('id',id,'at',at,'label',label,'data',data) into strict result from recovery_private.snapshots where id=p_id;return result;end $$;
create function recovery_private.daily_backup() returns void language plpgsql security definer set search_path='' as $$
begin perform recovery_private.take_snapshot('Automatic daily backup');
 delete from recovery_private.snapshots where label='Automatic daily backup' and at<now()-interval '14 days';
 delete from recovery_private.events where at<now()-interval '90 days';
 delete from recovery_private.plans where at<now()-interval '1 day';
end $$;
create function public.recovery_status() returns jsonb language sql security invoker set search_path='' as $$ select recovery_private.status() $$;
create function public.recovery_changes(p_from timestamptz,p_to timestamptz,p_actor uuid default null,p_deleted boolean default false,p_offset int default 0) returns jsonb language sql security invoker set search_path='' as $$ select recovery_private.list_changes(p_from,p_to,p_actor,p_deleted,p_offset) $$;
create function public.recovery_preview(p_mode text,p_ids bigint[] default null,p_snapshot uuid default null) returns jsonb language sql security invoker set search_path='' as $$ select recovery_private.preview(p_mode,p_ids,p_snapshot) $$;
create function public.recovery_apply(p_plan uuid) returns jsonb language sql security invoker set search_path='' as $$ select recovery_private.apply(p_plan) $$;
create function public.recovery_snapshot() returns uuid language plpgsql security invoker set search_path='' as $$ begin perform recovery_private.require_owner();return recovery_private.take_snapshot('Owner backup');end $$;
create function public.recovery_download(p_id uuid) returns jsonb language sql security invoker set search_path='' as $$ select recovery_private.download(p_id) $$;
create function public.recovery_lock(p_user uuid default null,p_locked boolean default true) returns void language sql security invoker set search_path='' as $$ select recovery_private.set_lock(p_user,p_locked) $$;
revoke all on all functions in schema recovery_private from public,anon,authenticated;
grant execute on function recovery_private.require_owner(),recovery_private.status(),recovery_private.list_changes(timestamptz,timestamptz,uuid,boolean,int),recovery_private.preview(text,bigint[],uuid),recovery_private.apply(uuid),recovery_private.take_snapshot(text),recovery_private.download(uuid),recovery_private.set_lock(uuid,boolean) to authenticated;
-- take_snapshot is called only through Owner-gated functions, so gate its direct authenticated entry too.

do $$ declare t record;p record;begin
 for t in select tablename from pg_tables where schemaname='recovery_private' loop execute format('create policy owner_read on recovery_private.%I for select to authenticated using ((select recovery_private.is_owner()))',t.tablename);end loop;
 for p in select oid::regprocedure sig from pg_proc where pronamespace='public'::regnamespace and proname like 'recovery_%' loop execute format('revoke all on function %s from public,anon',p.sig);execute format('grant execute on function %s to authenticated',p.sig);end loop;
end $$;
create extension if not exists pg_cron;
select cron.schedule('owner-recovery-daily','15 9 * * *','select recovery_private.daily_backup()');

select recovery_private.take_snapshot('Initial protected backup');
