-- Cancel draft manifests without cancelling deliveries or releasing their reserved date.
alter table public.manifests add column if not exists cancelled_at timestamptz;
alter table public.manifests add column if not exists cancellation_reason text;
alter table public.manifests add column if not exists cancelled_by uuid references public.profiles(id);
alter table public.manifests add column if not exists cancelled_stop_count integer;
create or replace function private.sgi_manifest_reverse_draft(p_manifest uuid,p_stop uuid,p_reason text)
returns integer language plpgsql security definer set search_path='' as $$
declare m public.manifests%rowtype; r record; v_count integer:=0; v_expected integer; v_reason text:=btrim(coalesce(p_reason,''));
begin
 if auth.uid() is null or length(v_reason) not between 5 and 500 then raise exception 'Informe justificativa de 5 a 500 caracteres';end if;
 select * into m from public.manifests where id=p_manifest for update;
 if not found or m.status<>'draft' or m.dispatched_at is not null or not private.sgi_can_manage_manifest(m.id) then raise exception 'Somente romaneios em rascunho e autorizados podem ser alterados';end if;
 -- Empty drafts may be cancelled by their creator or a manager with access to the full central.
 if not exists(select 1 from public.manifest_stops where manifest_id=m.id) and m.created_by is distinct from auth.uid()
 and not private.is_tenant_admin(m.tenant_id)
 and exists(select 1 from public.logistics_pool_branches pb join public.branches br on br.id=pb.branch_id where pb.pool_id=m.pool_id and not private.allowed(br.company_id,br.id,'shipping.write'))
 then raise exception 'Sem autorização para cancelar este romaneio';end if;
 select count(*) into v_expected from public.manifest_stops where manifest_id=m.id and (p_stop is null or id=p_stop);
 if p_stop is not null and v_expected<>1 then raise exception 'Entrega não pertence mais a este romaneio';end if;
 for r in select st.id stop_id,st.booking_id,st.sequence_no,st.status stop_status,b.status booking_status,b.company_id,b.branch_id,b.tenant_id,b.delivery_date,b.slot_id
 from public.manifest_stops st join public.delivery_bookings b on b.id=st.booking_id
 where st.manifest_id=m.id and (p_stop is null or st.id=p_stop)
 order by b.id for update of b,st
 loop
  if r.stop_status<>'loaded' or r.booking_status<>'loaded' or r.delivery_date<>m.route_date or r.tenant_id<>m.tenant_id or not private.allowed(r.company_id,r.branch_id,'shipping.write') then raise exception 'Carga inconsistente ou entrega fora do seu acesso. Nenhuma alteração realizada';end if;
  insert into public.audit_logs(tenant_id,company_id,actor_id,action,entity_type,entity_id,changes)
  values(r.tenant_id,r.company_id,auth.uid(),'manifest.stop_removed','delivery_booking',r.booking_id,jsonb_build_object('manifest_id',m.id,'stop_id',r.stop_id,'sequence_no',r.sequence_no,'date',r.delivery_date,'reason',v_reason,'previous_status','loaded','new_status','scheduled'));
  delete from public.manifest_stops where id=r.stop_id and manifest_id=m.id;
  update public.delivery_bookings set status='scheduled' where id=r.booking_id;
  v_count:=v_count+1;
 end loop;
 if v_count<>v_expected then raise exception 'Carga alterada. Atualize antes de repetir';end if;
 if p_stop is null then
  update public.manifests set status='cancelled',cancelled_at=now(),cancelled_by=auth.uid(),cancellation_reason=v_reason,cancelled_stop_count=v_count where id=m.id;
 end if;
 insert into public.audit_logs(tenant_id,actor_id,action,entity_type,entity_id,changes)
 values(m.tenant_id,auth.uid(),case when p_stop is null then 'manifest.cancelled' else 'manifest.stop_removed' end,'manifest',m.id,jsonb_build_object('date',m.route_date,'reason',v_reason,'released_stops',v_count,'previous_status','draft','new_status',case when p_stop is null then 'cancelled' else 'draft' end));
 return v_count;
end $$;
create or replace function public.sgi_manifest_cancel(p_manifest uuid,p_reason text) returns integer language sql set search_path='' as $$select private.sgi_manifest_reverse_draft($1,null,$2)$$;
create or replace function public.sgi_manifest_remove_stop(p_manifest uuid,p_stop uuid,p_reason text) returns integer language sql set search_path='' as $$select private.sgi_manifest_reverse_draft($1,$2,$3)$$;
revoke all on function private.sgi_manifest_reverse_draft(uuid,uuid,text),public.sgi_manifest_cancel(uuid,text),public.sgi_manifest_remove_stop(uuid,uuid,text) from public,anon,authenticated;
grant execute on function private.sgi_manifest_reverse_draft(uuid,uuid,text),public.sgi_manifest_cancel(uuid,text),public.sgi_manifest_remove_stop(uuid,uuid,text) to authenticated;
