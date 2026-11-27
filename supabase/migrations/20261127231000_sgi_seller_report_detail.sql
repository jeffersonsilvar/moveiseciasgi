-- Read-only detail with the same scope and competence rules as monthly commission report.
create or replace function private.sgi_seller_report_detail(p_company uuid,p_month date,p_seller uuid,p_day date,p_offset integer,p_limit integer)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_start date; v_end date; result jsonb;
begin
 if auth.uid() is null or p_month is null or not exists(select 1 from public.branches b where b.company_id=p_company and private.allowed(b.company_id,b.id,'report.read')) then raise exception 'Sem acesso ao relatório'; end if;
 v_start:=date_trunc('month',p_month::timestamp)::date; v_end:=(v_start+interval '1 month')::date;
 if p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 100 or (p_day is not null and (p_day<v_start or p_day>=v_end)) then raise exception 'Filtro inválido';end if;
 with scoped as materialized (
 select o.id,o.company_id,o.order_number,o.branch_id,coalesce(o.commercial_seller_id,o.seller_user_id) seller_id,
 coalesce(nullif(cs.display_name,''),nullif(pr.display_name,''),'Vendedor') seller_name,
 coalesce(o.confirmed_at,o.created_at) sold_at,(coalesce(o.confirmed_at,o.created_at) at time zone 'America/Recife')::date sold_day,
 o.confirmed_at is null legacy_date,o.products_gross,o.products_discount,o.products_gross-o.products_discount products_net,
 coalesce(o.customer_snapshot->>'name','') customer,br.name branch_name
 from public.orders o join public.branches br on br.id=o.branch_id and br.company_id=o.company_id
 left join public.commercial_sellers cs on cs.id=o.commercial_seller_id
 left join public.profiles pr on pr.id=o.seller_user_id
 where o.company_id=p_company and o.commercial_status in ('confirmed','closed') and o.deleted_at is null
 and coalesce(o.confirmed_at,o.created_at)>=(coalesce(p_day,v_start)::timestamp at time zone 'America/Recife')
 and coalesce(o.confirmed_at,o.created_at)<((case when p_day is null then v_end else p_day+1 end)::timestamp at time zone 'America/Recife')
 and (p_seller is null or coalesce(o.commercial_seller_id,o.seller_user_id)=p_seller)
 and private.allowed(o.company_id,o.branch_id,'report.read')
 and (o.seller_user_id=auth.uid() or private.allowed(o.company_id,o.branch_id,'admin.read'))
 ), page as (
 select * from scoped order by sold_at desc,id desc limit p_limit offset p_offset
 ), details as (
 select p.*,coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'name',i.name,'color',i.color,'size_text',i.size_text,'quantity',i.quantity,'unit_price',i.unit_price) order by i.id) from public.order_items i where i.order_id=p.id and i.company_id=p.company_id),'[]'::jsonb) items from page p
 )
 select jsonb_build_object('count',(select count(*) from scoped),'gross',(select coalesce(sum(products_gross),0) from scoped),'discount',(select coalesce(sum(products_discount),0) from scoped),'net',(select coalesce(sum(products_net),0) from scoped),'rows',coalesce((select jsonb_agg(to_jsonb(d) order by d.sold_at desc,d.id desc) from details d),'[]'::jsonb)) into result;
 return result;
end $$;
create or replace function public.sgi_seller_report_detail(p_company uuid,p_month date,p_seller uuid,p_day date,p_offset integer,p_limit integer) returns jsonb language sql stable set search_path='' as $$select private.sgi_seller_report_detail($1,$2,$3,$4,$5,$6)$$;
revoke all on function public.sgi_seller_report_detail(uuid,date,uuid,date,integer,integer),private.sgi_seller_report_detail(uuid,date,uuid,date,integer,integer) from public,anon,authenticated;
grant execute on function public.sgi_seller_report_detail(uuid,date,uuid,date,integer,integer),private.sgi_seller_report_detail(uuid,date,uuid,date,integer,integer) to authenticated;
