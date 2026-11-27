CREATE OR REPLACE FUNCTION private.sgi_smart_schedule(p_company uuid, p_branch uuid, p_order uuid, p_manual jsonb, p_pool uuid, p_date date, p_capacity integer, p_booking uuid, p_expected_date date, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o public.orders%rowtype;b public.delivery_bookings%rowtype; s public.delivery_slots%rowtype; v_tenant uuid;v_region uuid;v_id uuid;v_used int;v_old_pool uuid;v_manual jsonb;v_type text;v_seller_id uuid;v_seller_name text;v_seller_count int;v_today date:=(now() at time zone 'America/Recife')::date;
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
  if v_manual is null or jsonb_typeof(v_manual)<>'object' or octet_length(v_manual::text)>12000 then raise exception 'Dados do talão inválidos';end if;
  if p_booking is null then
   if nullif(btrim(coalesce(v_manual->>'seller_id','')),'') is not null then
    select cs.id,cs.display_name into v_seller_id,v_seller_name from public.commercial_sellers cs where cs.id::text=btrim(v_manual->>'seller_id') and cs.tenant_id=v_tenant and cs.company_id=p_company and cs.active and (cs.branch_id is null or cs.branch_id=p_branch) for share;
    if not found then raise exception 'Vendedor inválido, inativo ou não vinculado à loja';end if;
   else
    -- Compatibility for the previous interface until the new build is published; only an exact unambiguous active match is allowed.
    select count(*) into v_seller_count from public.commercial_sellers cs where cs.tenant_id=v_tenant and cs.company_id=p_company and cs.active and (cs.branch_id is null or cs.branch_id=p_branch) and lower(btrim(cs.display_name))=lower(btrim(coalesce(v_manual->>'seller','')));
    if v_seller_count<>1 then raise exception 'Selecione um vendedor cadastrado e ativo na loja; atualize a página';end if;
    select cs.id,cs.display_name into v_seller_id,v_seller_name from public.commercial_sellers cs where cs.tenant_id=v_tenant and cs.company_id=p_company and cs.active and (cs.branch_id is null or cs.branch_id=p_branch) and lower(btrim(cs.display_name))=lower(btrim(coalesce(v_manual->>'seller',''))) for share;
    if not found then raise exception 'Vendedor indisponível';end if;
   end if;
   v_manual:=v_manual||jsonb_build_object('seller_id',v_seller_id,'seller',v_seller_name);
  end if;
  if length(btrim(coalesce(v_manual->>'reference',''))) not between 1 and 80
   or length(btrim(coalesce(v_manual->>'customer',''))) not between 2 and 150
   or length(btrim(coalesce(v_manual->>'seller',''))) not between 2 and 120
   or length(btrim(coalesce(v_manual->>'products',''))) not between 2 and 3000
   or length(btrim(coalesce(v_manual->>'city',''))) not between 2 and 100
   or length(btrim(coalesce(v_manual->>'neighborhood',''))) not between 2 and 100
   or coalesce(v_manual->>'released','false')<>'true'
   then raise exception 'Preencha os dados do talão e confirme a liberação financeira e dos produtos'; end if;
  v_manual:=jsonb_build_object('reference',btrim(v_manual->>'reference'),'customer',btrim(v_manual->>'customer'),'seller',btrim(v_manual->>'seller'),'seller_id',v_manual->'seller_id','products',btrim(v_manual->>'products'),'city',btrim(v_manual->>'city'),'neighborhood',btrim(v_manual->>'neighborhood'),'cep',left(regexp_replace(coalesce(v_manual->>'cep',''),'[^0-9]','','g'),8),'street',left(coalesce(v_manual->>'street',''),180),'number',left(coalesce(v_manual->>'number',''),40),'phone',left(coalesce(v_manual->>'phone',''),40),'notes',left(coalesce(v_manual->>'notes',''),1000),'released',true);
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
 jsonb_build_object('old_date',b.delivery_date,'new_date',p_date,'reason',p_reason,'source',case when p_order is null then 'manual' else 'digital' end,'commercial_seller_id',case when p_order is null then v_manual->'seller_id' else to_jsonb(o.commercial_seller_id) end));
 return v_id;
end $function$
;
