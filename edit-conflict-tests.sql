begin;
do $test$
declare uid uuid;rid uuid;row_json jsonb;rev bigint;r jsonb;n int;
begin
 select user_id into uid from dock_private.user_access where role='Owner' limit 1;
 if uid is null then raise exception 'No owner test account';end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',uid,'role','authenticated','email','conflict-test@example.invalid')::text,true);
 execute 'set local role authenticated';
 select to_jsonb(t) into row_json from public.docks t limit 1;
 rid:=(row_json->>'id')::uuid;rev:=(row_json->>'edit_revision')::bigint;
 r:=public.guarded_edit('docks',array[rid],jsonb_build_object(rid::text,rev),jsonb_build_object('status',row_json->>'status'));
 if not (r->>'ok')::boolean then raise exception 'First edit failed: %',r;end if;
 if ((r->'rows'->0)->>'edit_revision')::bigint<>rev+1 then raise exception 'Revision did not advance';end if;
 r:=public.guarded_edit('docks',array[rid],jsonb_build_object(rid::text,rev),jsonb_build_object('status',row_json->>'status'));
 if (r->>'ok')::boolean or not (r->>'conflict')::boolean then raise exception 'Stale overwrite accepted: %',r;end if;
 select count(*) into n from public.edit_attempts where record_id=rid and actor_id=uid and actor_name='conflict-test' and outcome in ('applied','conflict');
 if n<2 then raise exception 'Audit attempt missing';end if;
 r:=public.guarded_edit('docks',array[rid],jsonb_build_object(rid::text,rev+1),jsonb_build_object('edit_revision',900));
 if (r->>'ok')::boolean then raise exception 'Protected revision accepted';end if;
 if not exists(select 1 from public.edit_attempts where record_id=rid and outcome='rejected' and actor_name='conflict-test') then raise exception 'Rejected attempt missing';end if;
end $test$;
select 'PASS: first edit, stale conflict, revisions, applied/conflict/rejected audit and identity protection' result;
rollback;