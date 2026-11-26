-- Unified smart agenda: native orders and paper-ticket deliveries.
alter table public.delivery_regions add column if not exists smart_system boolean not null default false;
alter table public.delivery_slots add column if not exists smart_route boolean not null default false;
create unique index if not exists sgi_one_smart_day on public.delivery_slots(pool_id,delivery_date) where smart_route;
alter table public.delivery_bookings alter column order_id drop not null;
alter table public.delivery_bookings add column if not exists manual_order jsonb;
alter table public.delivery_bookings add constraint sgi_booking_source check (
 (order_id is not null and manual_order is null) or
 (order_id is null and manual_order is not null and jsonb_typeof(manual_order)='object'
 and coalesce(manual_order->>'reference','')<>'' and coalesce(manual_order->>'released','false')='true'));
create unique index if not exists sgi_manual_reference_unique on public.delivery_bookings(company_id,branch_id,lower(btrim(manual_order->>'reference'))) where order_id is null and status<>'cancelled';
drop policy if exists delivery_bookings_read on public.delivery_bookings;
create policy delivery_bookings_read on public.delivery_bookings for select to authenticated using (
 (order_id is not null and private.allowed(company_id,branch_id,'orders.read.all'))
 or (order_id is null and private.allowed(company_id,branch_id,'shipping.consult')));

-- Resolve the location from a real order, or from the proposed paper-ticket address.
create or replace function private.sgi_smart_suggestions(p_company uuid,p_branch uuid,p_order uuid,p_address jsonb,p_booking uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype; b public.delivery_bookings%rowtype; v_tenant uuid; v_address jsonb; v_result jsonb; v_today date:=(now() at time zone 'America/Recife')::date;
begin
 if auth.uid() is null or not private.allowed(p_company,p_branch,'shipping.consult') then raise exception 'Sem autorização logística'; end if;
 select tenant_id into v_tenant from public.companies where id=p_company and active;
 if p_booking is not null then
  select * into b from public.delivery_bookings where id=p_booking and company_id=p_company and branch_id=p_branch and status='scheduled';
  if not found or not private.allowed(p_company,p_branch,'shipping.write') then raise exception 'Agendamento indisponível'; end if;
  p_order:=b.order_id; p_address:=b.manual_order;
 end if;
 if p_order is not null then
  select * into o from public.orders where id=p_order and company_id=p_company and branch_id=p_branch and commercial_status='confirmed' and deleted_at is null;
  if not found then raise exception 'Pedido indisponível'; end if;
  v_address:=o.delivery_address_snapshot;
 else v_address:=p_address; end if;
 if length(btrim(coalesce(v_address->>'city','')))<2 or length(btrim(coalesce(v_address->>'neighborhood','')))<2 then raise exception 'Informe cidade e bairro'; end if;
 with dest as (
  select lat,lon from public.sgi_postcode_geocodes where tenant_id=v_tenant and cep=regexp_replace(coalesce(v_address->>'cep',''),'[^0-9]','','g')
 ), days as (
  select s.id,s.pool_id,s.delivery_date,s.capacity,lp.name as pool_name,
   (select coalesce(sum(x.reserved),0)::int from public.delivery_slots x where x.pool_id=s.pool_id and x.delivery_date=s.delivery_date) as used
  from public.delivery_slots s join public.logistics_pools lp on lp.id=s.pool_id and lp.active
  join public.logistics_pool_branches pb on pb.pool_id=s.pool_id and pb.branch_id=p_branch
  where s.tenant_id=v_tenant and s.smart_route and s.active and s.delivery_date between v_today and v_today+45
  and (p_booking is null or (s.pool_id=(select pool_id from public.delivery_slots where id=b.slot_id) and s.delivery_date<>b.delivery_date))
 ), scored as (
  select d.*,coalesce(g.same_neighborhood,0) same_neighborhood,coalesce(g.same_city,0) same_city,g.nearest_km,coalesce(g.geo_count,0) geo_count,
   case when coalesce(g.same_neighborhood,0)>0 then 'same_neighborhood'
        when g.nearest_km<=5 then 'nearby'
        when g.nearest_km<=12 then 'moderate'
        when coalesce(g.same_city,0)>0 and g.nearest_km is null then 'same_city'
        when d.used=0 then 'empty'
        when g.nearest_km is not null then 'far' else 'unknown' end signal
  from days d left join lateral (
   select count(*) filter(where private.sgi_location_key(z.address->>'city')=private.sgi_location_key(v_address->>'city') and private.sgi_location_key(z.address->>'neighborhood')=private.sgi_location_key(v_address->>'neighborhood')) same_neighborhood,
    count(*) filter(where private.sgi_location_key(z.address->>'city')=private.sgi_location_key(v_address->>'city')) same_city,
    min(private.sgi_haversine_km(ref.lat,ref.lon,geo.lat,geo.lon)) nearest_km,
    count(geo.lat) geo_count
   from (select coalesce(po.delivery_address_snapshot,pb2.manual_order) address from public.delivery_bookings pb2 join public.delivery_slots sx on sx.id=pb2.slot_id
    left join public.orders po on po.id=pb2.order_id
    where sx.pool_id=d.pool_id and sx.delivery_date=d.delivery_date and pb2.status in ('scheduled','loaded','in_route') and pb2.id is distinct from p_booking) z
   left join public.sgi_postcode_geocodes geo on geo.tenant_id=v_tenant and geo.cep=regexp_replace(coalesce(z.address->>'cep',''),'[^0-9]','','g')
   left join dest ref on true
  ) g on true where d.used<d.capacity
 )
 select coalesce(jsonb_agg(to_jsonb(q) order by q.rank,q.delivery_date,q.nearest_km nulls last),'[]'::jsonb) into v_result
 from (select scored.*,case signal when 'same_neighborhood' then 1 when 'nearby' then 2 when 'moderate' then 3 when 'same_city' then 4 when 'empty' then 5 when 'far' then 6 else 7 end rank
       from scored order by rank,delivery_date,nearest_km nulls last limit 30) q;
 return v_result;
end $$;

create or replace function private.sgi_smart_schedule(p_company uuid,p_branch uuid,p_order uuid,p_manual jsonb,p_pool uuid,p_date date,p_capacity int,p_booking uuid,p_expected_date date,p_reason text)
returns uuid language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype;b public.delivery_bookings%rowtype; s public.delivery_slots%rowtype; v_tenant uuid;v_region uuid;v_id uuid;v_used int;v_old_pool uuid;v_manual jsonb;v_type text;v_today date:=(now() at time zone 'America/Recife')::date;
begin
 if auth.uid() is null or not (private.allowed(p_company,p_branch,'shipping.book') or private.allowed(p_company,p_branch,'shipping.write')) then raise exception 'Sem autorização para agendar'; end if;
 if p_date is null or p_date<v_today or p_date>v_today+180 then raise exception 'Selecione data válida nos próximos 180 dias'; end if;
 select tenant_id into v_tenant from public.companies where id=p_company and active;
 if p_booking is not null then
  select * into b from public.delivery_bookings where id=p_booking and company_id=p_company and branch_id=p_branch;
  if not found or not private.allowed(p_company,p_branch,'shipping.write') then raise exception 'Sem autorização para remarcar'; end if;
  p_order:=b.order_id;
 end if;
 if p_order is not null then
  select * into o from public.orders where id=p_order and company_id=p_company and branch_id=p_branch for update;
  if not found or o.commercial_status<>'confirmed' or o.deleted_at is not null or (o.financial_status<>'paid' and o.financial_override_at is null)
   or exists(select 1 from public.order_items where order_id=o.id and availability_status<>'ready')
   or (o.fulfillment_type='pickup' and o.assembly=0) or length(btrim(coalesce(o.delivery_address_snapshot->>'city','')))<2 or length(btrim(coalesce(o.delivery_address_snapshot->>'neighborhood','')))<2
   then raise exception 'Pedido bloqueado ou endereço incompleto'; end if;
  v_type:=case when o.fulfillment_type='pickup' then 'assembly' else 'delivery' end;
 else
  if not private.allowed(p_company,p_branch,'shipping.write') then raise exception 'Entrega avulsa exige acesso à expedição'; end if;
  v_manual:=case when p_booking is not null then b.manual_order else p_manual end;
  if v_manual is null or jsonb_typeof(v_manual)<>'object' or octet_length(v_manual::text)>12000
   or length(btrim(coalesce(v_manual->>'reference',''))) not between 1 and 80
   or length(btrim(coalesce(v_manual->>'customer',''))) not between 2 and 150
   or length(btrim(coalesce(v_manual->>'seller',''))) not between 2 and 120
   or length(btrim(coalesce(v_manual->>'products',''))) not between 2 and 3000
   or length(btrim(coalesce(v_manual->>'city',''))) not between 2 and 100
   or length(btrim(coalesce(v_manual->>'neighborhood',''))) not between 2 and 100
   or coalesce(v_manual->>'released','false')<>'true'
   then raise exception 'Preencha os dados do talão e confirme a liberação financeira e dos produtos'; end if;
  v_manual:=jsonb_build_object('reference',btrim(v_manual->>'reference'),'customer',btrim(v_manual->>'customer'),'seller',btrim(v_manual->>'seller'),'products',btrim(v_manual->>'products'),'city',btrim(v_manual->>'city'),'neighborhood',btrim(v_manual->>'neighborhood'),'cep',left(regexp_replace(coalesce(v_manual->>'cep',''),'[^0-9]','','g'),8),'street',left(coalesce(v_manual->>'street',''),180),'number',left(coalesce(v_manual->>'number',''),40),'phone',left(coalesce(v_manual->>'phone',''),40),'notes',left(coalesce(v_manual->>'notes',''),1000),'released',true);
  v_type:='delivery';
 end if;
 if p_booking is not null then
  select * into b from public.delivery_bookings where id=p_booking and company_id=p_company and branch_id=p_branch for update;
  if not found or b.status<>'scheduled' or b.delivery_date is distinct from p_expected_date or p_date=b.delivery_date or exists(select 1 from public.manifest_stops where booking_id=b.id)
   or length(btrim(coalesce(p_reason,''))) not between 5 and 500 then raise exception 'Remarcação inválida: confira data original, nova data e justificativa'; end if;
  select pool_id into v_old_pool from public.delivery_slots where id=b.slot_id;
  if v_old_pool is distinct from p_pool then raise exception 'Remarcação deve manter a mesma central'; end if;
 elsif p_order is not null and exists(select 1 from public.delivery_bookings where order_id=p_order and status<>'cancelled') then raise exception 'Pedido já agendado'; end if;
 -- Pool lock serializes all increases in shared day capacity, including the legacy booking RPC.
 perform 1 from public.logistics_pools lp where lp.id=p_pool and lp.tenant_id=v_tenant and lp.active
  and exists(select 1 from public.logistics_pool_branches pb where pb.pool_id=lp.id and pb.branch_id=p_branch) for update;
 if not found then raise exception 'Central não atende esta loja'; end if;
 select * into s from public.delivery_slots where pool_id=p_pool and delivery_date=p_date and smart_route for update;
 if not found then
  if not private.allowed(p_company,p_branch,'shipping.write') or p_capacity is null or p_capacity not between 1 and 100 then raise exception 'Abertura de data exige expedição e capacidade aprovada'; end if;
  insert into public.delivery_regions(tenant_id,name,smart_system) values(v_tenant,'Agenda inteligente (sistema)',true)
    on conflict(tenant_id,name) do nothing;
  select id into v_region from public.delivery_regions where tenant_id=v_tenant and name='Agenda inteligente (sistema)' and smart_system and active;
  if v_region is null then raise exception 'Região interna indisponível'; end if;
  insert into public.delivery_slots(tenant_id,pool_id,region_id,delivery_date,capacity,smart_route) values(v_tenant,p_pool,v_region,p_date,p_capacity,true) returning * into s;
  insert into public.audit_logs(tenant_id,company_id,actor_id,action,entity_type,entity_id,changes) values(v_tenant,p_company,auth.uid(),'smart_day.opened','delivery_slot',s.id,jsonb_build_object('date',p_date,'capacity',p_capacity));
 elsif not s.active then raise exception 'Data desativada'; end if;
 select coalesce(sum(reserved),0)::int into v_used from public.delivery_slots where pool_id=p_pool and delivery_date=p_date;
 if v_used>=s.capacity then raise exception 'Capacidade diária esgotada'; end if;
 if p_booking is not null then
  update public.delivery_slots set reserved=reserved-1 where id=b.slot_id and reserved>0;
  if not found then raise exception 'Reserva anterior inconsistente'; end if;
  update public.delivery_bookings set slot_id=s.id,delivery_date=p_date where id=b.id;
  v_id:=b.id;
 else
  insert into public.delivery_bookings(tenant_id,company_id,branch_id,order_id,slot_id,service_type,delivery_date,booked_by,manual_order)
   values(v_tenant,p_company,p_branch,p_order,s.id,v_type,p_date,auth.uid(),v_manual) returning id into v_id;
 end if;
 update public.delivery_slots set reserved=reserved+1 where id=s.id;
 insert into public.audit_logs(tenant_id,company_id,actor_id,action,entity_type,entity_id,changes)
 values(v_tenant,p_company,auth.uid(),case when p_booking is null then 'smart_delivery.booked' else 'smart_delivery.rescheduled' end,'delivery_booking',v_id,
 jsonb_build_object('old_date',b.delivery_date,'new_date',p_date,'reason',p_reason,'source',case when p_order is null then 'manual' else 'digital' end));
 return v_id;
end $$;

create or replace function public.sgi_smart_suggestions(p_company uuid,p_branch uuid,p_order uuid,p_address jsonb,p_booking uuid)
returns jsonb language sql set search_path='' as $$select private.sgi_smart_suggestions($1,$2,$3,$4,$5)$$;
create or replace function public.sgi_smart_schedule(p_company uuid,p_branch uuid,p_order uuid,p_manual jsonb,p_pool uuid,p_date date,p_capacity int,p_booking uuid,p_expected_date date,p_reason text)
returns uuid language sql set search_path='' as $$select private.sgi_smart_schedule($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)$$;
revoke all on function private.sgi_smart_suggestions(uuid,uuid,uuid,jsonb,uuid),public.sgi_smart_suggestions(uuid,uuid,uuid,jsonb,uuid),private.sgi_smart_schedule(uuid,uuid,uuid,jsonb,uuid,date,int,uuid,date,text),public.sgi_smart_schedule(uuid,uuid,uuid,jsonb,uuid,date,int,uuid,date,text) from public,anon,authenticated;
grant execute on function private.sgi_smart_suggestions(uuid,uuid,uuid,jsonb,uuid),public.sgi_smart_suggestions(uuid,uuid,uuid,jsonb,uuid),private.sgi_smart_schedule(uuid,uuid,uuid,jsonb,uuid,date,int,uuid,date,text),public.sgi_smart_schedule(uuid,uuid,uuid,jsonb,uuid,date,int,uuid,date,text) to authenticated;

CREATE OR REPLACE FUNCTION private.sgi_book_delivery(p_order uuid, p_slot uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o public.orders%rowtype;s public.delivery_slots%rowtype;v_booking uuid;v_type text;
begin
 select * into o from public.orders where id=p_order for update;
 if not found or not (private.allowed(o.company_id,o.branch_id,'shipping.book') or private.allowed(o.company_id,o.branch_id,'shipping.write')) then raise exception 'Sem acesso ao pedido'; end if;
 if o.commercial_status<>'confirmed' or o.deleted_at is not null then raise exception 'Pedido não confirmado'; end if;
 if o.financial_status<>'paid' and o.financial_override_at is null then raise exception 'Bloqueio financeiro: existe saldo não liberado'; end if;
 if exists(select 1 from public.order_items i where i.order_id=p_order and i.availability_status<>'ready')
 then raise exception 'Bloqueio: fabricação ou encomenda não liberada'; end if;
 if o.fulfillment_type='pickup' and o.assembly=0 then raise exception 'Retirada simples não exige rota'; end if;
 if o.delivery_address_snapshot='{}'::jsonb then raise exception 'Pedido sem endereço de serviço'; end if;
 perform 1 from public.logistics_pools lp where lp.id=(select pool_id from public.delivery_slots where id=p_slot) for update;
 select * into s from public.delivery_slots where id=p_slot for update;
 if not found or not s.active or s.tenant_id<>o.tenant_id or s.delivery_date<current_date
 or s.reserved>=s.capacity then raise exception 'Data sem disponibilidade'; end if;
 if s.smart_route then raise exception 'Use a agenda inteligente para esta data'; end if;
 if exists(select 1 from public.delivery_slots sd where sd.pool_id=s.pool_id and sd.delivery_date=s.delivery_date and sd.smart_route and (select coalesce(sum(x.reserved),0) from public.delivery_slots x where x.pool_id=s.pool_id and x.delivery_date=s.delivery_date)>=sd.capacity) then raise exception 'Capacidade diária da central esgotada'; end if;
 if not exists(select 1 from public.logistics_pool_branches m where m.pool_id=s.pool_id and m.branch_id=o.branch_id)
 or not exists(select 1 from public.delivery_region_areas a where a.region_id=s.region_id
  and private.sgi_location_key(a.city)=private.sgi_location_key(o.delivery_address_snapshot->>'city')
  and private.sgi_location_key(a.neighborhood)=private.sgi_location_key(o.delivery_address_snapshot->>'neighborhood'))
 then raise exception 'Data não atende a região deste endereço'; end if;
 if exists(select 1 from public.delivery_bookings b where b.order_id=p_order and b.status<>'cancelled') then raise exception 'Pedido já possui agendamento'; end if;
 v_type:=case when o.fulfillment_type='pickup' then 'assembly' else 'delivery' end;
 insert into public.delivery_bookings(tenant_id,company_id,branch_id,order_id,slot_id,service_type,delivery_date,booked_by)
 values(o.tenant_id,o.company_id,o.branch_id,o.id,s.id,v_type,s.delivery_date,auth.uid()) returning id into v_booking;
 update public.delivery_slots set reserved=reserved+1 where id=s.id;
 insert into public.audit_logs(tenant_id,company_id,actor_id,action,entity_type,entity_id,changes)
 values(o.tenant_id,o.company_id,auth.uid(),'delivery.booked','delivery_booking',v_booking,jsonb_build_object('date',s.delivery_date,'service',v_type));
 return v_booking;
end; $function$
;
CREATE OR REPLACE FUNCTION private.sgi_save_delivery_slot(p_pool uuid, p_region uuid, p_date date, p_capacity integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_tenant uuid;v_id uuid;
begin
 select tenant_id into v_tenant from public.logistics_pools where id=p_pool and active;
 if v_tenant is null or not private.is_tenant_admin(v_tenant) then raise exception 'Acesso negado'; end if;
 if not exists(select 1 from public.delivery_regions where id=p_region and tenant_id=v_tenant and active and not smart_system)
 or p_date<current_date or p_capacity<1 or p_capacity>100 then raise exception 'Capacidade ou região inválida'; end if;
 insert into public.delivery_slots(tenant_id,pool_id,region_id,delivery_date,capacity)
 values(v_tenant,p_pool,p_region,p_date,p_capacity)
 on conflict(pool_id,region_id,delivery_date)
 do update set capacity=excluded.capacity,active=true
 where public.delivery_slots.reserved<=excluded.capacity
 returning id into v_id;
 if v_id is null then raise exception 'Capacidade inferior às reservas já feitas'; end if;
 insert into public.audit_logs(tenant_id,actor_id,action,entity_type,entity_id,changes)
 values(v_tenant,auth.uid(),'slot.upsert','delivery_slot',v_id,jsonb_build_object('capacity',p_capacity,'date',p_date));
 return v_id;
end; $function$
;
CREATE OR REPLACE FUNCTION private.sgi_manage_region(p_tenant uuid, p_region uuid, p_action text, p_name text DEFAULT NULL::text, p_locations jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_region uuid:=p_region; v_area jsonb; v_city text; v_neighborhood text;
 v_existed boolean; v_added integer:=0; v_removed integer:=0; v_owner uuid;
begin
 if not private.is_tenant_admin(p_tenant) then raise exception 'Somente o administrador do grupo pode editar regiões'; end if;
 if p_action not in ('create','rename','add_areas','remove_areas','archive','restore') then raise exception 'Ação inválida'; end if;
 if jsonb_typeof(coalesce(p_locations,'[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_locations,'[]'::jsonb))>80 then
   raise exception 'Informe até 80 bairros por operação';
 end if;
 -- Serializes concurrent changes to the geography dictionary of this tenant.
 perform pg_advisory_xact_lock(hashtext(p_tenant::text));
 if p_action='create' then
   if char_length(trim(coalesce(p_name,'')))<3 then raise exception 'Nome de região inválido'; end if;
   insert into public.delivery_regions(tenant_id,name) values(p_tenant,trim(p_name)) returning id into v_region;
 else
   select tenant_id into v_owner from public.delivery_regions where id=p_region for update;
   if v_owner is null or v_owner<>p_tenant then raise exception 'Região inexistente ou de outro grupo'; end if;
 end if;
 if exists(select 1 from public.delivery_regions where id=v_region and smart_system) then raise exception 'Região interna da agenda inteligente'; end if;
 if p_action='rename' then
   if char_length(trim(coalesce(p_name,'')))<3 then raise exception 'Nome inválido'; end if;
   update public.delivery_regions set name=trim(p_name) where id=v_region;
 elsif p_action='archive' then
   if exists(select 1 from public.delivery_slots s where s.region_id=v_region and s.reserved>0 and s.delivery_date>=current_date) then
     raise exception 'Região possui entregas futuras reservadas. Reagende antes de desativar.';
   end if;
   update public.delivery_regions set active=false where id=v_region;
   update public.delivery_slots set active=false where region_id=v_region and delivery_date>=current_date and reserved=0;
 elsif p_action='restore' then
   update public.delivery_regions set active=true where id=v_region;
 end if;
 if p_action in ('create','add_areas','remove_areas') then
   if p_action<>'remove_areas' and not exists(select 1 from public.delivery_regions where id=v_region and active) then
     raise exception 'Reative esta região para editar bairros';
   end if;
   for v_area in select value from jsonb_array_elements(coalesce(p_locations,'[]'::jsonb)) loop
     v_city:=trim(coalesce(v_area->>'city',''));v_neighborhood:=trim(coalesce(v_area->>'neighborhood',''));
     if char_length(v_city)<2 or char_length(v_neighborhood)<2 or char_length(v_city)>100 or char_length(v_neighborhood)>100 then
       raise exception 'Cidade e bairro devem ter de 2 a 100 caracteres';
     end if;
     if p_action in ('create','add_areas') then
       if exists (
        select 1 from public.delivery_region_areas a
        join public.delivery_regions r on r.id=a.region_id
        where r.tenant_id=p_tenant and r.active and r.id<>v_region
         and private.sgi_location_key(a.city)=private.sgi_location_key(v_city)
         and private.sgi_location_key(a.neighborhood)=private.sgi_location_key(v_neighborhood)
       ) then raise exception 'Bairro % / % já pertence a outra região ativa',v_neighborhood,v_city;end if;
       select exists(select 1 from public.delivery_region_areas a where a.region_id=v_region
        and private.sgi_location_key(a.city)=private.sgi_location_key(v_city)
        and private.sgi_location_key(a.neighborhood)=private.sgi_location_key(v_neighborhood)) into v_existed;
       if not v_existed then
         insert into public.delivery_region_areas(region_id,city,neighborhood)
         values(v_region,lower(v_city),lower(v_neighborhood));v_added:=v_added+1;
       end if;
     else
       if exists (
         select 1 from public.delivery_bookings b
         join public.delivery_slots s on s.id=b.slot_id
         join public.orders o on o.id=b.order_id
         where s.region_id=v_region and b.status in ('scheduled','loaded','in_route')
           and private.sgi_location_key(o.delivery_address_snapshot->>'city')=private.sgi_location_key(v_city)
           and private.sgi_location_key(o.delivery_address_snapshot->>'neighborhood')=private.sgi_location_key(v_neighborhood)
       ) then raise exception 'Bairro possui entregas ativas. Reagende antes de removê-lo.';end if;
       delete from public.delivery_region_areas a where a.region_id=v_region
         and private.sgi_location_key(a.city)=private.sgi_location_key(v_city)
         and private.sgi_location_key(a.neighborhood)=private.sgi_location_key(v_neighborhood);
       get diagnostics v_removed = row_count;
     end if;
   end loop;
 end if;
 insert into public.audit_logs(tenant_id,actor_id,action,entity_type,entity_id,changes)
 values(p_tenant,auth.uid(),'region.'||p_action,'delivery_region',v_region,
 jsonb_build_object('name',p_name,'areas',p_locations,'added',v_added));
 return jsonb_build_object('region_id',v_region,'action',p_action,'added',v_added);
end $function$
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
 if not found or m.status<>'draft' or not private.is_tenant_admin(m.tenant_id)
 then raise exception 'Sem autorização para iniciar rota'; end if;
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
