
create or replace function private.sgi_dispatch_queue(p_company uuid,p_page int default 0,p_size int default 10)
returns jsonb language plpgsql security definer set search_path=''
as $body$
declare v_total bigint:=0;v_rows jsonb:='[]'::jsonb;
begin
 if auth.uid() is null or p_page is null or p_page<0 or p_size is null or p_size not between 1 and 50 then
  raise exception 'Consulta inválida';
 end if;
 if not exists(
  select 1 from public.branches br
  where br.company_id=p_company and private.allowed(p_company,br.id,'orders.read')
 ) then raise exception 'Sem autorização para consultar a expedição'; end if;

 select count(*) into v_total from public.orders o
 where o.company_id=p_company and o.commercial_status='confirmed' and o.deleted_at is null
 and (o.fulfillment_type='delivery' or (o.fulfillment_type='pickup' and o.assembly>0))
 and private.allowed(o.company_id,o.branch_id,'orders.read')
 and not exists(select 1 from public.delivery_bookings b where b.order_id=o.id and b.status<>'cancelled');

 select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at desc),'[]'::jsonb) into v_rows
 from (
  select o.id as order_id,o.order_number,o.created_at,
    coalesce(o.customer_snapshot->>'name','Cliente') as customer_name,
    coalesce(o.delivery_address_snapshot->>'neighborhood','') as neighborhood,
    coalesce(o.delivery_address_snapshot->>'city','') as city,
    o.fulfillment_type,o.financial_status,o.grand_total,
    (select count(*) from public.order_items i where i.order_id=o.id and i.availability_status<>'ready') as pending_items,
    case
     when o.financial_status<>'paid' and o.financial_override_at is null then 'financial'
     when exists(select 1 from public.order_items i where i.order_id=o.id and i.availability_status<>'ready') then 'production'
     when coalesce(o.delivery_address_snapshot->>'city','')='' or coalesce(o.delivery_address_snapshot->>'neighborhood','')='' then 'address'
     when not exists (
      select 1 from public.delivery_region_areas a
      join public.delivery_regions r on r.id=a.region_id and r.active and r.tenant_id=o.tenant_id
      join public.logistics_pool_branches pb on pb.branch_id=o.branch_id
      join public.logistics_pools pool on pool.id=pb.pool_id and pool.tenant_id=o.tenant_id and pool.active
      where a.city=lower(trim(o.delivery_address_snapshot->>'city'))
        and a.neighborhood=lower(trim(o.delivery_address_snapshot->>'neighborhood'))
     ) then 'region'
     when not exists (
      select 1 from public.delivery_slots s
      join public.delivery_regions r on r.id=s.region_id and r.active
      join public.delivery_region_areas a on a.region_id=r.id
      join public.logistics_pool_branches pb on pb.pool_id=s.pool_id and pb.branch_id=o.branch_id
      where s.tenant_id=o.tenant_id and s.active
        and s.delivery_date between current_date and current_date+45
        and s.reserved<s.capacity
        and a.city=lower(trim(o.delivery_address_snapshot->>'city'))
        and a.neighborhood=lower(trim(o.delivery_address_snapshot->>'neighborhood'))
     ) then 'capacity'
     else 'ready'
    end as stage
  from public.orders o
  where o.company_id=p_company and o.commercial_status='confirmed' and o.deleted_at is null
    and (o.fulfillment_type='delivery' or (o.fulfillment_type='pickup' and o.assembly>0))
    and private.allowed(o.company_id,o.branch_id,'orders.read')
    and not exists(select 1 from public.delivery_bookings b where b.order_id=o.id and b.status<>'cancelled')
  order by o.created_at desc limit p_size offset (p_page*p_size)
 ) q;
 return jsonb_build_object('total',v_total,'rows',v_rows);
end
$body$;
revoke all on function private.sgi_dispatch_queue(uuid,int,int) from public,anon;
grant execute on function private.sgi_dispatch_queue(uuid,int,int) to authenticated;

create or replace function public.sgi_dispatch_queue(p_company uuid,p_page int default 0,p_size int default 10)
returns jsonb language sql security invoker set search_path=''
as $$ select private.sgi_dispatch_queue(p_company,p_page,p_size) $$;
revoke all on function public.sgi_dispatch_queue(uuid,int,int) from public,anon;
grant execute on function public.sgi_dispatch_queue(uuid,int,int) to authenticated;

-- Allow the shipping team to book slots for confirmed, paid, production-released orders,
-- while preserving all existing validation and transactional slot locks.
do $guard$
declare def text; needle text;
begin
 select pg_get_functiondef('private.sgi_book_delivery(uuid,uuid)'::regprocedure) into def;
 needle:='not private.allowed(o.company_id,o.branch_id,''orders.write'')';
 if position(needle in def)=0 then
   raise exception 'A regra de autorização atual mudou; revisão manual obrigatória';
 end if;
 execute replace(def,needle,
  'not (private.allowed(o.company_id,o.branch_id,''orders.write'') or private.allowed(o.company_id,o.branch_id,''shipping.write''))');
end
$guard$;
