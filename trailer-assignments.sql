-- Trailer assignments use the existing shared docks.trailer_number field.
-- Deferred uniqueness permits atomic destination transfer + source clearing.
ALTER TABLE public.docks ADD CONSTRAINT docks_trailer_number_unique UNIQUE (trailer_number) DEFERRABLE INITIALLY DEFERRED;

CREATE OR REPLACE FUNCTION dock_private.assign_trailer(p_dock_id uuid, p_trailer_number text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE v_number text := nullif(upper(trim(p_trailer_number)), ''); v_target public.docks%rowtype;
BEGIN
  IF auth.uid() IS NULL OR NOT dock_private.can('update_status') THEN
    RAISE EXCEPTION 'Dock status access required' USING ERRCODE = '42501';
  END IF;
  IF v_number IS NULL OR length(v_number)>30 OR v_number !~ '^[A-Z0-9-]+$' THEN
    RAISE EXCEPTION 'Choose a valid trailer number';
  END IF;
  PERFORM pg_advisory_xact_lock(7130132026);
  SELECT * INTO v_target FROM public.docks WHERE id=p_dock_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Dock not found'; END IF;
  IF v_target.trailer_number IS NOT DISTINCT FROM v_number THEN RETURN; END IF;
  UPDATE public.docks SET trailer_number=null, updated_by=auth.uid(), updated_by_email=auth.jwt()->>'email'
    WHERE trailer_number=v_number AND id<>p_dock_id;
  UPDATE public.docks SET trailer_number=v_number, updated_by=auth.uid(), updated_by_email=auth.jwt()->>'email'
    WHERE id=p_dock_id;
END;
$function$;
REVOKE ALL ON FUNCTION dock_private.assign_trailer(uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION dock_private.assign_trailer(uuid,text) TO authenticated;
CREATE OR REPLACE FUNCTION public.assign_dock_trailer(p_dock_id uuid,p_trailer_number text)
RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path = '' AS $function$
  SELECT dock_private.assign_trailer(p_dock_id,p_trailer_number);
$function$;
REVOKE ALL ON FUNCTION public.assign_dock_trailer(uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.assign_dock_trailer(uuid,text) TO authenticated;

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

