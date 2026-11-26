CREATE OR REPLACE FUNCTION private.sgi_manifest_complete_stop(p_stop uuid, p_success boolean, p_notes text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare m public.manifests%rowtype;b public.delivery_bookings%rowtype;
begin
 select mm.* into m from public.manifests mm join public.manifest_stops s on s.manifest_id=mm.id
 where s.id=p_stop for update of mm;
 select bb.* into b from public.delivery_bookings bb join public.manifest_stops s on s.booking_id=bb.id
 where s.id=p_stop for update of bb;
 if m.id is null or b.id is null or m.status<>'dispatched' or
 not private.allowed(b.company_id,b.branch_id,'shipping.write') then raise exception 'Operação não autorizada'; end if;
 if not exists(select 1 from public.manifest_stops where id=p_stop and status='loaded') then raise exception 'Parada já encerrada'; end if;
 if not p_success and length(trim(coalesce(p_notes,'')))<5 then raise exception 'Motivo da ocorrência obrigatório'; end if;
 update public.manifest_stops set status=case when p_success then 'delivered' else 'failed' end,
 notes=left(p_notes,500),updated_at=now() where id=p_stop;
 update public.delivery_bookings set status=case when p_success then 'delivered' else 'failed' end,
 completed_at=now(),delivery_notes=left(p_notes,500) where id=b.id;
 insert into public.audit_logs(tenant_id,company_id,actor_id,action,entity_type,entity_id,changes)
 values(b.tenant_id,b.company_id,auth.uid(),'delivery.completed','delivery_booking',b.id,jsonb_build_object('success',p_success,'notes',left(p_notes,200)));
end; $function$
;
