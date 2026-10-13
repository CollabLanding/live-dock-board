CREATE TABLE public.trailer_activity (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 dock_id uuid NOT NULL REFERENCES public.docks(id),
 building integer NOT NULL,
 dock_number integer NOT NULL,
 trailer_number text NOT NULL,
 action text NOT NULL CHECK (action IN ('Attached','Released')),
 changed_at timestamptz NOT NULL DEFAULT now(),
 changed_by uuid,
 changed_by_email text
);
ALTER TABLE public.trailer_activity ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.trailer_activity TO authenticated;
REVOKE ALL ON public.trailer_activity FROM anon;
CREATE POLICY "Board users can read trailer activity" ON public.trailer_activity FOR SELECT TO authenticated USING (dock_private.can('view_board'));
CREATE INDEX trailer_activity_changed_at_idx ON public.trailer_activity (changed_at DESC,id DESC);
CREATE OR REPLACE FUNCTION dock_private.log_trailer_activity()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $function$
BEGIN
 IF old.trailer_number IS NOT DISTINCT FROM new.trailer_number THEN RETURN new; END IF;
 IF nullif(trim(old.trailer_number),'') IS NOT NULL THEN
  INSERT INTO public.trailer_activity(dock_id,building,dock_number,trailer_number,action,changed_by,changed_by_email)
  VALUES(new.id,new.building,new.dock_number,old.trailer_number,'Released',coalesce(auth.uid(),new.updated_by),coalesce(auth.jwt()->>'email',new.updated_by_email));
 END IF;
 IF nullif(trim(new.trailer_number),'') IS NOT NULL THEN
  INSERT INTO public.trailer_activity(dock_id,building,dock_number,trailer_number,action,changed_by,changed_by_email)
  VALUES(new.id,new.building,new.dock_number,new.trailer_number,'Attached',coalesce(auth.uid(),new.updated_by),coalesce(auth.jwt()->>'email',new.updated_by_email));
 END IF;
 RETURN new;
END;
$function$;
REVOKE ALL ON FUNCTION dock_private.log_trailer_activity() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER log_trailer_assignment AFTER UPDATE OF trailer_number ON public.docks FOR EACH ROW EXECUTE FUNCTION dock_private.log_trailer_activity();
ALTER PUBLICATION supabase_realtime ADD TABLE public.trailer_activity;

CREATE OR REPLACE FUNCTION dock_private.release_trailer(p_dock_id uuid,p_expected_trailer_number text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $function$
DECLARE d public.docks%rowtype;
BEGIN
 IF auth.uid() IS NULL OR NOT dock_private.can('update_status') THEN RAISE EXCEPTION 'Dock status access required' USING ERRCODE='42501'; END IF;
 SELECT * INTO d FROM public.docks WHERE id=p_dock_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Dock not found'; END IF;
 IF d.trailer_number IS DISTINCT FROM p_expected_trailer_number THEN RAISE EXCEPTION 'The attached trailer changed. Reopen the dock and try again.'; END IF;
 UPDATE public.docks SET trailer_number=null,updated_by=auth.uid(),updated_by_email=auth.jwt()->>'email' WHERE id=p_dock_id;
END;
$function$;
REVOKE ALL ON FUNCTION dock_private.release_trailer(uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION dock_private.release_trailer(uuid,text) TO authenticated;
CREATE OR REPLACE FUNCTION public.release_dock_trailer(p_dock_id uuid,p_expected_trailer_number text)
RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $function$
 SELECT dock_private.release_trailer(p_dock_id,p_expected_trailer_number);
$function$;
REVOKE ALL ON FUNCTION public.release_dock_trailer(uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.release_dock_trailer(uuid,text) TO authenticated;
