-- Backwards-compatible API guards: route legacy calls through audited operations.
create or replace function private.sgi_create_region(p_tenant uuid,p_name text,p_city text,p_neighborhood text)
returns uuid language plpgsql security definer set search_path='' as $fn$
declare v_id uuid; v_result jsonb;
begin
 if not private.is_tenant_admin(p_tenant) then raise exception 'Sem permissão para regiões'; end if;
 select id into v_id from public.delivery_regions
 where tenant_id=p_tenant and name=trim(p_name) and active for update;
 v_result:=private.sgi_manage_region(p_tenant,v_id,
  case when v_id is null then 'create' else 'add_areas' end,
  case when v_id is null then trim(p_name) else null end,
  jsonb_build_array(jsonb_build_object('city',p_city,'neighborhood',p_neighborhood)));
 return (v_result->>'region_id')::uuid;
end $fn$;
revoke all on function private.sgi_create_region(uuid,text,text,text) from public,anon;
grant execute on function private.sgi_create_region(uuid,text,text,text) to authenticated;

create or replace function private.sgi_release_item(p_item uuid,p_eta date)
returns void language plpgsql security definer set search_path='' as $fn$
declare v_status text;
begin
 select availability_status into v_status from public.order_items where id=p_item;
 if v_status is null then raise exception 'Item não encontrado'; end if;
 perform private.sgi_change_item_availability(p_item,
  case when p_eta is null then 'ready' else v_status end,
  case when p_eta is null then 'Conferência da fabricação registrada pela rotina anterior' else 'Previsão atualizada pela rotina anterior' end,
  p_eta);
end $fn$;
revoke all on function private.sgi_release_item(uuid,date) from public,anon;
grant execute on function private.sgi_release_item(uuid,date) to authenticated;
