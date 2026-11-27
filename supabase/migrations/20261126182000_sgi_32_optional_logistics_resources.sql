-- Optional transport resources: default to a simple operational agenda.
create table if not exists private.sgi_logistics_policies (
 tenant_id uuid primary key references public.tenants(id) on delete cascade,
 require_vehicle boolean not null default false,
 require_driver boolean not null default false,
 enforce_vehicle_stops boolean not null default false,
 revision integer not null default 0,
 constraint sgi_vehicle_stops_requires_vehicle check(not enforce_vehicle_stops or require_vehicle)
);
alter table private.sgi_logistics_policies enable row level security;
revoke all on private.sgi_logistics_policies from public,anon,authenticated;
alter table public.manifests add column if not exists logistics_policy jsonb not null default '{"require_vehicle":false,"require_driver":false,"enforce_vehicle_stops":false,"revision":0}'::jsonb;
create or replace function private.sgi_logistics_policy_value(p_tenant uuid)
returns jsonb language sql stable set search_path='' as $$
 select coalesce((select jsonb_build_object('require_vehicle',require_vehicle,'require_driver',require_driver,'enforce_vehicle_stops',enforce_vehicle_stops,'revision',revision) from private.sgi_logistics_policies where tenant_id=p_tenant),
 '{"require_vehicle":false,"require_driver":false,"enforce_vehicle_stops":false,"revision":0}'::jsonb)
$$;
revoke all on function private.sgi_logistics_policy_value(uuid) from public,anon,authenticated;
create or replace function private.sgi_get_logistics_policy(p_tenant uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not private.can_see_tenant(p_tenant) then raise exception 'Acesso negado';end if;
 return private.sgi_logistics_policy_value(p_tenant);
end $$;
create or replace function private.sgi_set_logistics_policy(p_tenant uuid,p_revision int,p_vehicle boolean,p_driver boolean,p_stops boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare old jsonb; v_new jsonb;
begin
 if auth.uid() is null or not private.is_tenant_admin(p_tenant) then raise exception 'Somente o Master pode alterar parâmetros logísticos';end if;
 if p_revision is null or p_vehicle is null or p_driver is null or p_stops is null or (p_stops and not p_vehicle) then raise exception 'Controle por veículo exige veículo obrigatório';end if;
 perform 1 from public.tenants where id=p_tenant and active for update;
 if not found then raise exception 'Grupo indisponível';end if;
 old:=private.sgi_logistics_policy_value(p_tenant);
 if (old->>'revision')::int<>p_revision then raise exception 'Parâmetros alterados por outro administrador. Atualize a tela';end if;
 if p_vehicle and not exists(select 1 from public.vehicles where tenant_id=p_tenant and active) then raise exception 'Cadastre pelo menos um veículo ativo antes de torná-lo obrigatório';end if;
 if p_driver and not exists(select 1 from public.drivers where tenant_id=p_tenant and active) then raise exception 'Cadastre pelo menos um motorista ativo antes de torná-lo obrigatório';end if;
 insert into private.sgi_logistics_policies(tenant_id,require_vehicle,require_driver,enforce_vehicle_stops,revision)
 values(p_tenant,p_vehicle,p_driver,p_stops,p_revision+1)
 on conflict(tenant_id) do update set require_vehicle=excluded.require_vehicle,require_driver=excluded.require_driver,enforce_vehicle_stops=excluded.enforce_vehicle_stops,revision=excluded.revision;
 v_new:=private.sgi_logistics_policy_value(p_tenant);
 insert into public.audit_logs(tenant_id,actor_id,action,entity_type,entity_id,changes)
 values(p_tenant,auth.uid(),'logistics.policy_changed','tenant',p_tenant,jsonb_build_object('before',old,'after',v_new));
 return v_new;
end $$;
-- Manifest-wide operations require authority over every linked booking, not merely a shared pool.
create or replace function private.sgi_can_manage_manifest(p_manifest uuid)
returns boolean language sql stable set search_path='' as $$
 select auth.uid() is not null and exists(select 1 from public.manifests m where m.id=p_manifest and
 (private.is_tenant_admin(m.tenant_id) or exists(select 1 from public.logistics_pool_branches pb join public.branches br on br.id=pb.branch_id where pb.pool_id=m.pool_id and private.allowed(br.company_id,br.id,'shipping.write')))
 and not exists(select 1 from public.manifest_stops st join public.delivery_bookings b on b.id=st.booking_id where st.manifest_id=m.id and not private.allowed(b.company_id,b.branch_id,'shipping.write')))
$$;
revoke all on function private.sgi_can_manage_manifest(uuid) from public,anon,authenticated;
CREATE OR REPLACE FUNCTION private.sgi_create_manifest(p_pool uuid, p_vehicle uuid, p_driver uuid, p_date date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_tenant uuid;v_id uuid;v_policy jsonb;
begin
 select tenant_id into v_tenant from public.logistics_pools where id=p_pool and active;
 if v_tenant is null or not exists(
 select 1 from public.logistics_pool_branches m join public.branches b on b.id=m.branch_id
 where m.pool_id=p_pool and private.allowed(b.company_id,b.id,'shipping.write'))
 then raise exception 'Sem autorização para central logística'; end if;
 select private.sgi_logistics_policy_value(v_tenant) into v_policy;
 if auth.uid() is null or p_date is null or p_date<(now() at time zone 'America/Recife')::date then raise exception 'Data inválida';end if;
 if (v_policy->>'require_vehicle')::boolean and p_vehicle is null then raise exception 'Selecione o veículo conforme a política logística';end if;
 if (v_policy->>'require_driver')::boolean and p_driver is null then raise exception 'Selecione o motorista conforme a política logística';end if;
 if p_vehicle is not null and not exists(select 1 from public.vehicles where id=p_vehicle and tenant_id=v_tenant and active) then raise exception 'Veículo inválido ou inativo';end if;
 if p_driver is not null and not exists(select 1 from public.drivers where id=p_driver and tenant_id=v_tenant and active) then raise exception 'Motorista inválido ou inativo';end if;
 insert into public.manifests(tenant_id,pool_id,vehicle_id,driver_id,route_date,created_by,logistics_policy)
 values(v_tenant,p_pool,p_vehicle,p_driver,p_date,auth.uid(),v_policy) returning id into v_id;
 insert into public.audit_logs(tenant_id,actor_id,action,entity_type,entity_id) values
 (v_tenant,auth.uid(),'manifest.created','manifest',v_id);
 return v_id;
end; $function$
;
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
 if not found or m.id is null or m.status<>'draft' or b.status<>'scheduled'
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
CREATE OR REPLACE FUNCTION private.sgi_manifest_start(p_manifest uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare m public.manifests%rowtype;
begin
 select * into m from public.manifests where id=p_manifest for update;
 if not found or m.status<>'draft' or not private.sgi_can_manage_manifest(m.id)
 then raise exception 'Sem autorização para iniciar rota'; end if;
 if coalesce((m.logistics_policy->>'require_vehicle')::boolean,false) and not exists(select 1 from public.vehicles v where v.id=m.vehicle_id and v.tenant_id=m.tenant_id and v.active) then raise exception 'Veículo obrigatório indisponível';end if;
 if coalesce((m.logistics_policy->>'require_driver')::boolean,false) and not exists(select 1 from public.drivers d where d.id=m.driver_id and d.tenant_id=m.tenant_id and d.active) then raise exception 'Motorista obrigatório indisponível';end if;
 if coalesce((m.logistics_policy->>'enforce_vehicle_stops')::boolean,false) and not exists(select 1 from public.vehicles v where v.id=m.vehicle_id and v.tenant_id=m.tenant_id and v.active and v.capacity_stops>=(select count(*) from public.manifest_stops where manifest_id=m.id)) then raise exception 'Limite de paradas excedido';end if;
 if not exists(select 1 from public.manifest_stops where manifest_id=p_manifest) then raise exception 'Romaneio sem entregas'; end if;
 if exists(
 select 1 from public.manifest_stops st join public.delivery_bookings b on b.id=st.booking_id
 left join public.orders o on o.id=b.order_id where st.manifest_id=p_manifest
 and (b.status<>'loaded' or (b.order_id is null and coalesce(b.manual_order->>'released','false')<>'true') or (b.order_id is not null and (o.id is null or o.commercial_status<>'confirmed' or o.deleted_at is not null
 or (o.financial_status<>'paid' and o.financial_override_at is null)
 or exists(select 1 from public.order_items it where it.order_id=o.id and it.availability_status<>'ready'))))
 ) then raise exception 'Pedido bloqueado por disponibilidade ou financeiro'; end if;
 update public.manifests set status='dispatched',dispatched_at=now() where id=p_manifest;
 update public.delivery_bookings set status='in_route' where id in
 (select booking_id from public.manifest_stops where manifest_id=p_manifest);
 insert into public.audit_logs(tenant_id,actor_id,action,entity_type,entity_id)
 values(m.tenant_id,auth.uid(),'manifest.dispatched','manifest',m.id);
end; $function$
;
CREATE OR REPLACE FUNCTION private.sgi_manifest_close(p_manifest uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare m public.manifests%rowtype;
begin
 select * into m from public.manifests where id=p_manifest for update;
 if not found or m.status<>'dispatched' or not private.sgi_can_manage_manifest(m.id)
 then raise exception 'Acesso negado'; end if;
 if exists(select 1 from public.manifest_stops where manifest_id=p_manifest and status='loaded')
 then raise exception 'Todas as paradas devem ter uma baixa'; end if;
 update public.manifests set status='closed',returned_at=now(),closed_at=now() where id=p_manifest;
 insert into public.audit_logs(tenant_id,actor_id,action,entity_type,entity_id)
 values(m.tenant_id,auth.uid(),'manifest.closed','manifest',p_manifest);
end; $function$
;
create or replace function private.sgi_manifest_read_details(p_manifest uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.manifests%rowtype;v_rows jsonb;v_all boolean;
begin
 select * into m from public.manifests where id=p_manifest;
 if not found or auth.uid() is null or not (private.is_tenant_admin(m.tenant_id) or exists(select 1 from public.logistics_pool_branches pb join public.branches br on br.id=pb.branch_id where pb.pool_id=m.pool_id and private.allowed(br.company_id,br.id,'shipping.read'))) then raise exception 'Romaneio indisponível';end if;
 select not exists(select 1 from public.manifest_stops st join public.delivery_bookings b on b.id=st.booking_id where st.manifest_id=m.id and not private.allowed(b.company_id,b.branch_id,'shipping.read')) into v_all;
 select coalesce(jsonb_agg(to_jsonb(q) order by q.sequence_no),'[]'::jsonb) into v_rows from (
 select st.id,st.sequence_no,st.status,st.notes,b.id booking_id,b.order_id,b.order_id is null is_manual,
 coalesce(o.order_number::text,b.manual_order->>'reference') reference,
 coalesce(o.customer_snapshot->>'name',b.manual_order->>'customer') customer,
 coalesce(o.customer_snapshot->>'mobile',b.manual_order->>'phone','') phone,
 coalesce(cs.display_name,pr.display_name,b.manual_order->>'seller','Não informado') seller,
 coalesce((select string_agg(i.quantity::text||'× '||i.name||coalesce(' · '||nullif(i.color,''),'')||coalesce(' · '||nullif(i.size_text,''),''),'; ' order by i.id) from public.order_items i where i.order_id=o.id),b.manual_order->>'products','') products,
 br.name branch_name,coalesce(o.delivery_address_snapshot->>'street',b.manual_order->>'street','') street,
 coalesce(o.delivery_address_snapshot->>'number',b.manual_order->>'number','') street_number,
 coalesce(o.delivery_address_snapshot->>'neighborhood',b.manual_order->>'neighborhood','') neighborhood,
 coalesce(o.delivery_address_snapshot->>'city',b.manual_order->>'city','') city,
 coalesce(o.delivery_address_snapshot->>'cep',b.manual_order->>'cep','') cep,
 coalesce(o.delivery_address_snapshot->>'complement','') complement,
 coalesce(b.manual_order->>'notes',o.notes,'') delivery_notes,b.service_type,
 private.allowed(b.company_id,b.branch_id,'shipping.write') can_manage
 from public.manifest_stops st join public.delivery_bookings b on b.id=st.booking_id join public.branches br on br.id=b.branch_id
 left join public.orders o on o.id=b.order_id left join public.commercial_sellers cs on cs.id=o.commercial_seller_id left join public.profiles pr on pr.id=o.seller_user_id
 where st.manifest_id=m.id and private.allowed(b.company_id,b.branch_id,'shipping.read')
 ) q;
 return jsonb_build_object('rows',v_rows,'complete',v_all,'can_manage',private.sgi_can_manage_manifest(m.id));
end $$;
-- Date and pool-scoped selection, with names instead of internal UUIDs.
create or replace function private.sgi_manifest_candidates(p_manifest uuid,p_company uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.manifests%rowtype;v jsonb;
begin
 select * into m from public.manifests where id=p_manifest;
 if not found or auth.uid() is null or m.status<>'draft' or not exists(select 1 from public.logistics_pool_branches pb join public.branches br on br.id=pb.branch_id where pb.pool_id=m.pool_id and br.company_id=p_company and private.allowed(br.company_id,br.id,'shipping.write')) then raise exception 'Sem autorização para adicionar entregas';end if;
 select coalesce(jsonb_agg(to_jsonb(q) order by q.neighborhood,q.customer,q.id),'[]'::jsonb) into v from (
 select b.id,coalesce(o.order_number::text,b.manual_order->>'reference') reference,coalesce(o.customer_snapshot->>'name',b.manual_order->>'customer') customer,
 coalesce(o.delivery_address_snapshot->>'neighborhood',b.manual_order->>'neighborhood','') neighborhood,
 coalesce(o.delivery_address_snapshot->>'city',b.manual_order->>'city','') city,
 b.order_id is null is_manual
 from public.delivery_bookings b join public.delivery_slots s on s.id=b.slot_id left join public.orders o on o.id=b.order_id
 where b.company_id=p_company and s.pool_id=m.pool_id and b.delivery_date=m.route_date and b.status='scheduled' and private.allowed(b.company_id,b.branch_id,'shipping.write')
 ) q;
 return v;
end $$;
create or replace function private.sgi_manifest_add_selected(p_manifest uuid,p_company uuid,p_bookings uuid[])
returns integer language plpgsql security definer set search_path='' as $$
declare m public.manifests%rowtype;b uuid;v_count int:=0;
begin
 select * into m from public.manifests where id=p_manifest for update;
 if not found or auth.uid() is null or m.status<>'draft' or not private.sgi_can_manage_manifest(m.id) or coalesce(cardinality(p_bookings),0) not between 1 and 100 then raise exception 'Seleção de entregas inválida ou sem autorização';end if;
 for b in select distinct unnest(p_bookings) order by 1 loop
  if not exists(select 1 from public.delivery_bookings where id=b and company_id=p_company) then raise exception 'Entrega fora da empresa selecionada';end if;
  perform private.sgi_manifest_add_stop(m.id,b);v_count:=v_count+1;
 end loop;
 return v_count;
end $$;
create or replace function public.sgi_get_logistics_policy(p_tenant uuid) returns jsonb language sql set search_path='' as $$select private.sgi_get_logistics_policy($1)$$;
create or replace function public.sgi_set_logistics_policy(p_tenant uuid,p_revision int,p_vehicle boolean,p_driver boolean,p_stops boolean) returns jsonb language sql set search_path='' as $$select private.sgi_set_logistics_policy($1,$2,$3,$4,$5)$$;
create or replace function public.sgi_manifest_read_details(p_manifest uuid) returns jsonb language sql set search_path='' as $$select private.sgi_manifest_read_details($1)$$;
create or replace function public.sgi_manifest_candidates(p_manifest uuid,p_company uuid) returns jsonb language sql set search_path='' as $$select private.sgi_manifest_candidates($1,$2)$$;
create or replace function public.sgi_manifest_add_selected(p_manifest uuid,p_company uuid,p_bookings uuid[]) returns integer language sql set search_path='' as $$select private.sgi_manifest_add_selected($1,$2,$3)$$;
revoke all on function private.sgi_get_logistics_policy(uuid),public.sgi_get_logistics_policy(uuid),private.sgi_set_logistics_policy(uuid,int,boolean,boolean,boolean),public.sgi_set_logistics_policy(uuid,int,boolean,boolean,boolean),private.sgi_manifest_read_details(uuid),public.sgi_manifest_read_details(uuid),private.sgi_manifest_candidates(uuid,uuid),public.sgi_manifest_candidates(uuid,uuid),private.sgi_manifest_add_selected(uuid,uuid,uuid[]),public.sgi_manifest_add_selected(uuid,uuid,uuid[]) from public,anon,authenticated;
grant execute on function private.sgi_get_logistics_policy(uuid),public.sgi_get_logistics_policy(uuid),private.sgi_set_logistics_policy(uuid,int,boolean,boolean,boolean),public.sgi_set_logistics_policy(uuid,int,boolean,boolean,boolean),private.sgi_manifest_read_details(uuid),public.sgi_manifest_read_details(uuid),private.sgi_manifest_candidates(uuid,uuid),public.sgi_manifest_candidates(uuid,uuid),private.sgi_manifest_add_selected(uuid,uuid,uuid[]),public.sgi_manifest_add_selected(uuid,uuid,uuid[]) to authenticated;
