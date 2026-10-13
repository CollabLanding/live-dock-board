CREATE TABLE public.trailers(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 number text NOT NULL UNIQUE CHECK(number=upper(trim(number)) AND number ~ '^[A-Z0-9-]{1,30}$'),
 category text NOT NULL DEFAULT 'Active' CHECK(category IN ('Active','Storage')),
 location_label text NOT NULL DEFAULT '' CHECK(length(location_label)<=80),
 notes text NOT NULL DEFAULT '' CHECK(length(notes)<=5000),
 updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 updated_by uuid
);
ALTER TABLE public.trailers ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.trailers TO authenticated;
REVOKE ALL ON public.trailers FROM anon;
CREATE POLICY "Board users read trailers" ON public.trailers FOR SELECT TO authenticated USING(dock_private.can('view_board') OR dock_private.role() IN ('Owner','Admin'));
INSERT INTO public.trailers(number,category,location_label) VALUES ('GPS5150','Active',''),
('H08819','Active',''),
('H15257','Active',''),
('H15643','Active',''),
('H15649','Active',''),
('H15761','Active',''),
('H15817','Active',''),
('H15819','Active',''),
('U85250','Active',''),
('U98219','Active',''),
('W00514','Active',''),
('W02111','Active',''),
('W04979','Active',''),
('W10657','Active',''),
('W23496','Active',''),
('W23867','Active',''),
('W24822','Active',''),
('W25727','Active',''),
('W83691','Active',''),
('W84716','Active',''),
('W84935','Active',''),
('W85767','Active',''),
('W86005','Active',''),
('W87588','Active',''),
('W92475','Active',''),
('W99595','Active',''),
('Y10505','Active',''),
('318420','Storage','Allen Storage'),
('H15645','Storage','Allen Storage'),
('H15827','Storage','Allen Storage'),
('U90770','Storage','SV Storage'),
('U92344','Storage','Allen Storage'),
('U94421','Storage','SV Storage'),
('U95524','Storage','SV Storage'),
('W03511','Storage','Allen Storage'),
('W43897','Storage',''),
('W45858','Storage','Allen Storage'),
('W48970','Storage',''),
('Y10496','Storage','Allen Storage'),
('Y10509','Storage','Allen Storage'),
('Y10512','Storage','Allen Storage');
INSERT INTO public.trailers(number) SELECT DISTINCT upper(trim(trailer_number)) FROM public.docks WHERE nullif(trim(trailer_number),'') IS NOT NULL ON CONFLICT(number) DO NOTHING;
ALTER TABLE public.docks ADD CONSTRAINT docks_trailer_catalog_fk FOREIGN KEY(trailer_number) REFERENCES public.trailers(number) ON UPDATE CASCADE ON DELETE SET NULL;
ALTER PUBLICATION supabase_realtime ADD TABLE public.trailers;

CREATE OR REPLACE FUNCTION dock_private.save_trailer(p_id uuid,p_number text,p_category text,p_location_label text,p_notes text,p_expected_updated_at timestamptz)
RETURNS public.trailers LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $function$
DECLARE t public.trailers%rowtype;num text:=upper(trim(p_number));
BEGIN
 IF auth.uid() IS NULL OR dock_private.role() NOT IN ('Owner','Admin') THEN RAISE EXCEPTION 'Admin access required' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(7130132026);
 IF p_id IS NULL THEN
 INSERT INTO public.trailers(number,category,location_label,notes,updated_by) VALUES(num,p_category,coalesce(trim(p_location_label),''),coalesce(p_notes,''),auth.uid()) RETURNING * INTO t;
 ELSE
 SELECT * INTO t FROM public.trailers WHERE id=p_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Trailer not found';END IF;
 IF p_expected_updated_at IS NULL OR t.updated_at IS DISTINCT FROM p_expected_updated_at THEN RAISE EXCEPTION 'This trailer was edited by another user. Refresh and try again.';END IF;
 UPDATE public.trailers SET number=num,category=p_category,location_label=coalesce(trim(p_location_label),''),notes=coalesce(p_notes,''),updated_at=clock_timestamp(),updated_by=auth.uid() WHERE id=p_id RETURNING * INTO t;
 END IF;
 RETURN t;
END;$function$;
REVOKE ALL ON FUNCTION dock_private.save_trailer(uuid,text,text,text,text,timestamptz) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION dock_private.save_trailer(uuid,text,text,text,text,timestamptz) TO authenticated;
CREATE OR REPLACE FUNCTION public.save_trailer(p_id uuid,p_number text,p_category text,p_location_label text,p_notes text,p_expected_updated_at timestamptz DEFAULT NULL)
RETURNS public.trailers LANGUAGE sql SECURITY INVOKER SET search_path='' AS $function$
 SELECT dock_private.save_trailer(p_id,p_number,p_category,p_location_label,p_notes,p_expected_updated_at);
$function$;
REVOKE ALL ON FUNCTION public.save_trailer(uuid,text,text,text,text,timestamptz) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_trailer(uuid,text,text,text,text,timestamptz) TO authenticated;

CREATE OR REPLACE FUNCTION dock_private.remove_trailer(p_id uuid,p_expected_updated_at timestamptz)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $function$
DECLARE t public.trailers%rowtype;
BEGIN
 IF auth.uid() IS NULL OR dock_private.role() NOT IN ('Owner','Admin') THEN RAISE EXCEPTION 'Admin access required' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(7130132026);
 SELECT * INTO t FROM public.trailers WHERE id=p_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Trailer not found';END IF;
 IF p_expected_updated_at IS NULL OR t.updated_at IS DISTINCT FROM p_expected_updated_at THEN RAISE EXCEPTION 'This trailer was edited by another user. Refresh and try again.';END IF;
 DELETE FROM public.trailers WHERE id=p_id;
END;$function$;
REVOKE ALL ON FUNCTION dock_private.remove_trailer(uuid,timestamptz) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION dock_private.remove_trailer(uuid,timestamptz) TO authenticated;
CREATE OR REPLACE FUNCTION public.remove_trailer(p_id uuid,p_expected_updated_at timestamptz)
RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $function$
 SELECT dock_private.remove_trailer(p_id,p_expected_updated_at);
$function$;
REVOKE ALL ON FUNCTION public.remove_trailer(uuid,timestamptz) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.remove_trailer(uuid,timestamptz) TO authenticated;
