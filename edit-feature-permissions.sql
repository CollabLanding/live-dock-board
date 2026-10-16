begin;
 update dock_private.permission_config set catalog=catalog||'[{"key":"edit_history","label":"Edit History","group":"Administration and diagnostics","fixed":false,"adminOnly":false,"dependencies":[]},{"key":"live_connection","label":"Live Connection","group":"Administration and diagnostics","fixed":false,"adminOnly":false,"dependencies":[]}]'::jsonb,revision=revision+1 where not exists(select 1 from jsonb_array_elements(catalog) f where f->>'key'='edit_history');
 update dock_private.role_permissions set permissions=permissions||jsonb_build_object('edit_history',role='Admin','live_connection',role='Admin');
 drop policy if exists "Read edit history" on public.edit_attempts;
 create policy "Read edit history" on public.edit_attempts for select to authenticated using (dock_private.can('edit_history'));
 commit;