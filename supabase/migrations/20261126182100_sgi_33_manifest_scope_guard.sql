CREATE OR REPLACE FUNCTION private.sgi_manifest_add_stop(p_manifest uuid, p_booking uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare m public.manifests%rowtype;b public.delivery_bookings%rowtype;v_id uuid;v_seq int;
begin
 select * into m from public.manifests where id=p_manifest for update;
 select * into b from public.delivery_bookings where id=p_booking for update;
 if not found or m.id is null or m.status<>'draft' or not private.sgi_can_manage_manifest(m.id) or b.status<>'scheduled'
 or b.delivery_date<>m.route_date or not private.allowed(b.company_id,b.branch_id,'shipping.write')
 or not exists(select 1 from public.delivery_slots s where s.id=b.slot_id and s.pool_id=m.pool_id) then
 raise exception 'Entrega indisponível para esta carga'; end if;
 if coalesce((m.logistics_policy->>'enforce_vehicle_stops')::boolean,false) and not exists(select 1 from public.vehicles v where v.id=m.vehicle_id and v.tenant_id=m.tenant_id and v.active and v.capacity_stops>(select count(*) from public.manifest_stops where manifest_id=m.id)) then raise exception 'Limite de paradas do veículo atingido ou veículo indisponível';end if;
 select coalesce(max(sequence_no),0)+1 into v_seq from public.manifest_stops where manifest_id=p_manifest;
 insert into public.manifest_stops(manifest_id,booking_id,sequence_no)
 values(p_manifest,p_booking,v_seq) returning id into v_id;
 update public.delivery_bookings set status='loaded' where id=b.id;
 insert into public.audit_logs(tenant_id,company_id,actor_id,action,entity_type,entity_id)
 values(b.tenant_id,b.company_id,auth.uid(),'manifest.stop_added','delivery_booking',b.id);
 return v_id;
end; $function$
;
