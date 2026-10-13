CREATE OR REPLACE FUNCTION dock_private.save_dock_details(p_id uuid,p_notes text,p_is_hidden boolean,p_expected_updated_at timestamptz)
RETURNS public.docks LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $function$
DECLARE d public.docks%rowtype;
BEGIN
 IF auth.uid() IS NULL OR dock_private.role() NOT IN ('Owner','Admin') THEN RAISE EXCEPTION 'Admin access required' USING ERRCODE='42501';END IF;
 IF length(coalesce(p_notes,''))>5000 OR p_is_hidden IS NULL THEN RAISE EXCEPTION 'Invalid dock details';END IF;
 SELECT * INTO d FROM public.docks WHERE id=p_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Dock not found';END IF;
 IF p_expected_updated_at IS NULL OR d.updated_at IS DISTINCT FROM p_expected_updated_at THEN RAISE EXCEPTION 'This dock changed. Refresh and try again.';END IF;
 UPDATE public.docks SET notes=coalesce(p_notes,''),is_hidden=p_is_hidden,updated_by=auth.uid(),updated_by_email=auth.jwt()->>'email' WHERE id=p_id RETURNING * INTO d;
 RETURN d;
END;$function$;
REVOKE ALL ON FUNCTION dock_private.save_dock_details(uuid,text,boolean,timestamptz) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION dock_private.save_dock_details(uuid,text,boolean,timestamptz) TO authenticated;
CREATE OR REPLACE FUNCTION public.save_dock_details(p_id uuid,p_notes text,p_is_hidden boolean,p_expected_updated_at timestamptz)
RETURNS public.docks LANGUAGE sql SECURITY INVOKER SET search_path='' AS $function$
 SELECT dock_private.save_dock_details(p_id,p_notes,p_is_hidden,p_expected_updated_at);
$function$;
REVOKE ALL ON FUNCTION public.save_dock_details(uuid,text,boolean,timestamptz) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_dock_details(uuid,text,boolean,timestamptz) TO authenticated;
