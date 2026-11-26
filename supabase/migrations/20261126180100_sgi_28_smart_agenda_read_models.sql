-- Read models for unified agenda, plus own-order booking for operators with sales permission.
CREATE OR REPLACE FUNCTION private.sgi_smart_suggestions(p_company uuid, p_branch uuid, p_order uuid, p_address jsonb, p_booking uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o public.orders%rowtype; b public.delivery_bookings%rowtype; v_tenant uuid; v_address jsonb; v_result jsonb; v_today date:=(now() at time zone 'America/Recife')::date;
begin
 if auth.uid() is null or not (private.allowed(p_company,p_branch,'shipping.consult') or (p_booking is null and p_order is not null and private.allowed(p_company,p_branch,'orders.write') and exists(select 1 from public.orders oo where oo.id=p_order and oo.company_id=p_company and oo.branch_id=p_branch and oo.created_by=auth.uid() and oo.commercial_status='confirmed' and oo.deleted_at is null))) then raise exception 'Sem autorização logística'; end if;
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
end $function$
;
CREATE OR REPLACE FUNCTION private.sgi_smart_schedule(p_company uuid, p_branch uuid, p_order uuid, p_manual jsonb, p_pool uuid, p_date date, p_capacity integer, p_booking uuid, p_expected_date date, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o public.orders%rowtype;b public.delivery_bookings%rowtype; s public.delivery_slots%rowtype; v_tenant uuid;v_region uuid;v_id uuid;v_used int;v_old_pool uuid;v_manual jsonb;v_type text;v_today date:=(now() at time zone 'America/Recife')::date;
begin
 if auth.uid() is null or not (private.allowed(p_company,p_branch,'shipping.book') or private.allowed(p_company,p_branch,'shipping.write') or (p_booking is null and p_order is not null and private.allowed(p_company,p_branch,'orders.write') and exists(select 1 from public.orders oo where oo.id=p_order and oo.company_id=p_company and oo.branch_id=p_branch and oo.created_by=auth.uid() and oo.commercial_status='confirmed' and oo.deleted_at is null))) then raise exception 'Sem autorização para agendar'; end if;
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
end $function$
;
create or replace function private.sgi_smart_agenda(p_company uuid,p_from date,p_to date)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_rows jsonb;v_days jsonb;v_tenant uuid;
begin
 if auth.uid() is null or p_from is null or p_to is null or p_to<p_from or p_to-p_from>45
 or not exists(select 1 from public.branches br where br.company_id=p_company and private.allowed(p_company,br.id,'shipping.consult'))
 then raise exception 'Consulta logística não autorizada'; end if;
 select tenant_id into v_tenant from public.companies where id=p_company and active;
 select coalesce(jsonb_agg(to_jsonb(q) order by q.delivery_date,q.booked_at,q.id),'[]'::jsonb) into v_rows
 from (
 select b.id,b.order_id,b.company_id,b.branch_id,b.slot_id,b.delivery_date,b.status,b.service_type,b.booked_at,b.delivery_notes,
  s.pool_id,lp.name as pool_name,br.name as branch_name,
  coalesce(o.order_number::text,b.manual_order->>'reference') reference,
  coalesce(o.customer_snapshot->>'name',b.manual_order->>'customer') customer,
  coalesce(cs.display_name,pr.display_name,b.manual_order->>'seller','Não informado') seller,
  coalesce((select string_agg(i.quantity::text||'× '||i.name,', ' order by i.id) from public.order_items i where i.order_id=o.id),b.manual_order->>'products','') products,
  coalesce(o.delivery_address_snapshot->>'city',b.manual_order->>'city','') city,
  coalesce(o.delivery_address_snapshot->>'neighborhood',b.manual_order->>'neighborhood','') neighborhood,
  coalesce(o.delivery_address_snapshot->>'cep',b.manual_order->>'cep','') cep,
  coalesce(o.delivery_address_snapshot->>'street',b.manual_order->>'street','') street,
  coalesce(o.delivery_address_snapshot->>'number',b.manual_order->>'number','') street_number,
  coalesce(o.customer_snapshot->>'mobile',b.manual_order->>'phone','') phone,
  coalesce(b.manual_order->>'notes',o.notes,'') notes,
  b.order_id is null is_manual,
  private.allowed(b.company_id,b.branch_id,'shipping.write') can_manage
 from public.delivery_bookings b
 join public.delivery_slots s on s.id=b.slot_id join public.logistics_pools lp on lp.id=s.pool_id
 join public.branches br on br.id=b.branch_id
 left join public.orders o on o.id=b.order_id
 left join public.commercial_sellers cs on cs.id=o.commercial_seller_id
 left join public.profiles pr on pr.id=o.seller_user_id
 where b.company_id=p_company and b.delivery_date between p_from and p_to
  and private.allowed(b.company_id,b.branch_id,'shipping.consult')
 ) q;
 select coalesce(jsonb_agg(to_jsonb(q) order by q.delivery_date,q.pool_name),'[]'::jsonb) into v_days
 from (
 select s.pool_id,lp.name pool_name,s.delivery_date,s.capacity,s.active,
 (select coalesce(sum(x.reserved),0)::int from public.delivery_slots x where x.pool_id=s.pool_id and x.delivery_date=s.delivery_date) used
 from public.delivery_slots s join public.logistics_pools lp on lp.id=s.pool_id
 where s.tenant_id=v_tenant and s.smart_route and s.delivery_date between p_from and p_to
 and exists(select 1 from public.logistics_pool_branches pb join public.branches br on br.id=pb.branch_id where pb.pool_id=s.pool_id and br.company_id=p_company and private.allowed(p_company,br.id,'shipping.consult'))
 ) q;
 return jsonb_build_object('rows',v_rows,'days',v_days);
end $$;
create or replace function private.sgi_smart_history(p_booking uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare b public.delivery_bookings%rowtype;v jsonb;
begin
 select * into b from public.delivery_bookings where id=p_booking;
 if not found or auth.uid() is null or not private.allowed(b.company_id,b.branch_id,'shipping.consult') then raise exception 'Acesso negado'; end if;
 select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at desc),'[]'::jsonb) into v from (
  select a.action,a.created_at,coalesce(p.display_name,'Operador') actor,
   a.changes->>'old_date' old_date,a.changes->>'new_date' new_date,a.changes->>'date' booked_date,a.changes->>'reason' reason
  from public.audit_logs a left join public.profiles p on p.id=a.actor_id
  where a.tenant_id=b.tenant_id and a.company_id=b.company_id and a.entity_type='delivery_booking' and a.entity_id=b.id
  order by a.created_at desc,a.id desc limit 100
 ) q;
 return v;
end $$;
create or replace function public.sgi_smart_agenda(p_company uuid,p_from date,p_to date) returns jsonb language sql set search_path='' as $$select private.sgi_smart_agenda($1,$2,$3)$$;
create or replace function public.sgi_smart_history(p_booking uuid) returns jsonb language sql set search_path='' as $$select private.sgi_smart_history($1)$$;
revoke all on function public.sgi_smart_agenda(uuid,date,date),private.sgi_smart_agenda(uuid,date,date),public.sgi_smart_history(uuid),private.sgi_smart_history(uuid) from public,anon,authenticated;
grant execute on function public.sgi_smart_agenda(uuid,date,date),private.sgi_smart_agenda(uuid,date,date),public.sgi_smart_history(uuid),private.sgi_smart_history(uuid) to authenticated;
