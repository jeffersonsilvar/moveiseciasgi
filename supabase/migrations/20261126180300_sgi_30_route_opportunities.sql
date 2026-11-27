-- Regional fallback and demand clusters for route opening.
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
  select d.*,coalesce(g.same_neighborhood,0) same_neighborhood,coalesce(g.same_city,0) same_city,coalesce(g.same_region,0) same_region,g.nearest_km,coalesce(g.geo_count,0) geo_count,
   case when coalesce(g.same_neighborhood,0)>0 then 'same_neighborhood'
        when g.nearest_km<=5 then 'nearby'
        when g.nearest_km<=12 then 'moderate'
        when coalesce(g.same_region,0)>0 and g.nearest_km is null then 'same_region'
        when coalesce(g.same_city,0)>0 and g.nearest_km is null then 'same_city'
        when d.used=0 then 'empty'
        when g.nearest_km is not null then 'far' else 'unknown' end signal
  from days d left join lateral (
   select count(*) filter(where private.sgi_location_key(z.address->>'city')=private.sgi_location_key(v_address->>'city') and private.sgi_location_key(z.address->>'neighborhood')=private.sgi_location_key(v_address->>'neighborhood')) same_neighborhood,
    count(*) filter(where private.sgi_location_key(z.address->>'city')=private.sgi_location_key(v_address->>'city')) same_city,
    count(*) filter(where exists(select 1 from public.delivery_region_areas ar join public.delivery_regions rr on rr.id=ar.region_id and rr.tenant_id=v_tenant and rr.active and not rr.smart_system join public.delivery_region_areas br on br.region_id=ar.region_id where private.sgi_location_key(ar.city)=private.sgi_location_key(v_address->>'city') and private.sgi_location_key(ar.neighborhood)=private.sgi_location_key(v_address->>'neighborhood') and private.sgi_location_key(br.city)=private.sgi_location_key(z.address->>'city') and private.sgi_location_key(br.neighborhood)=private.sgi_location_key(z.address->>'neighborhood'))) same_region,
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
 from (select scored.*,case signal when 'same_neighborhood' then 1 when 'nearby' then 2 when 'moderate' then 3 when 'same_region' then 4 when 'same_city' then 5 when 'empty' then 6 when 'far' then 7 else 8 end rank
       from scored order by rank,delivery_date,nearest_km nulls last limit 30) q;
 return v_result;
end $function$
;
create or replace function private.sgi_smart_route_opportunities(p_company uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v jsonb;
begin
 if auth.uid() is null or not exists(select 1 from public.branches br where br.company_id=p_company and private.allowed(p_company,br.id,'shipping.consult')) then raise exception 'Acesso negado';end if;
 with waiting as (
 select o.id,o.order_number,o.created_at,o.delivery_address_snapshot->>'city' city,o.delivery_address_snapshot->>'neighborhood' neighborhood,
 coalesce(r.name,'Bairro · '||(o.delivery_address_snapshot->>'neighborhood')||' / '||(o.delivery_address_snapshot->>'city')) cluster,
 coalesce(r.id::text,private.sgi_location_key(o.delivery_address_snapshot->>'city')||':'||private.sgi_location_key(o.delivery_address_snapshot->>'neighborhood')) cluster_key
 from public.orders o
 left join lateral (select dr.id,dr.name from public.delivery_regions dr join public.delivery_region_areas da on da.region_id=dr.id where dr.tenant_id=o.tenant_id and dr.active and not dr.smart_system and private.sgi_location_key(da.city)=private.sgi_location_key(o.delivery_address_snapshot->>'city') and private.sgi_location_key(da.neighborhood)=private.sgi_location_key(o.delivery_address_snapshot->>'neighborhood') order by dr.id limit 1) r on true
 where o.company_id=p_company and o.commercial_status='confirmed' and o.deleted_at is null
 and (o.fulfillment_type='delivery' or (o.fulfillment_type='pickup' and o.assembly>0))
 and (o.financial_status='paid' or o.financial_override_at is not null)
 and not exists(select 1 from public.order_items i where i.order_id=o.id and i.availability_status<>'ready')
 and not exists(select 1 from public.delivery_bookings b where b.order_id=o.id and b.status<>'cancelled')
 and length(btrim(coalesce(o.delivery_address_snapshot->>'city','')))>=2 and length(btrim(coalesce(o.delivery_address_snapshot->>'neighborhood','')))>=2
 and private.allowed(o.company_id,o.branch_id,'shipping.consult')
 ), grouped as (
 select cluster_key,min(cluster) cluster,count(*) pending,min(created_at) oldest,
  (array_agg(id order by created_at,id))[1] first_order,
  array_agg(distinct neighborhood||' / '||city) destinations
 from waiting group by cluster_key
 )
 select coalesce(jsonb_agg(to_jsonb(q) order by q.pending desc,q.oldest),'[]'::jsonb) into v from (select * from grouped order by pending desc,oldest limit 12) q;
 return v;
end $$;
create or replace function public.sgi_smart_route_opportunities(p_company uuid) returns jsonb language sql set search_path='' as $$select private.sgi_smart_route_opportunities($1)$$;
revoke all on function public.sgi_smart_route_opportunities(uuid),private.sgi_smart_route_opportunities(uuid) from public,anon,authenticated;
grant execute on function public.sgi_smart_route_opportunities(uuid),private.sgi_smart_route_opportunities(uuid) to authenticated;
