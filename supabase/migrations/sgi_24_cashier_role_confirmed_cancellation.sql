-- Caixa independente; cancelamento administrativo; acesso por pedido.
-- Preserva os vínculos, os pedidos e os valores existentes.
alter table public.user_memberships drop constraint user_memberships_role_check;
alter table public.user_memberships add constraint user_memberships_role_check check (role in ('tenant_admin','company_admin','manager','seller','cashier','shipping','finance','production','viewer'));

CREATE OR REPLACE FUNCTION private.allowed(p_company uuid, p_branch uuid, p_action text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select (select auth.uid()) is not null and exists(
  select 1 from public.companies c
  join public.tenants t on t.id=c.tenant_id
  join public.user_memberships m on m.tenant_id=c.tenant_id
  join public.profiles p on p.id=m.user_id
  where c.id=p_company and c.active and t.active
    and m.user_id=(select auth.uid()) and m.active and p.active
    and (m.company_id is null or m.company_id=c.id)
    and (
      m.branch_id is null
      or (p_branch is not null and m.branch_id=p_branch)
      or (p_branch is null and p_action='catalog.read')
    )
    and (
      m.role in ('tenant_admin','company_admin')
      or (m.role='manager' and p_action not in ('admin.grant','admin.tenant','orders.cancel'))
      or (m.role='seller' and p_action in ('people.read','people.write','catalog.read','orders.read','orders.read.all','orders.write','orders.legacy','payments.read','report.read','shipping.consult','shipping.book')
      or (m.role='cashier' and p_action in ('people.read','people.write','catalog.read','orders.read','orders.write','payments.read')))
      or (m.role='shipping' and p_action in ('people.read','catalog.read','orders.read','orders.read.all','shipping.read','shipping.write','shipping.consult','shipping.book'))
      or (m.role='finance' and p_action in ('people.read','orders.read','orders.read.all','payments.read','payments.write'))
      or (m.role='production' and p_action in ('catalog.read','orders.read','orders.read.all','production.read','production.write'))
      or (m.role='viewer' and p_action in ('catalog.read','orders.read','orders.read.all'))
    )
 );
$function$
;

CREATE OR REPLACE FUNCTION private.create_order_impl(p_company uuid, p_branch uuid, p_customer uuid, p_seller uuid, p_fulfillment text, p_availability text, p_items jsonb, p_discount_kind text, p_discount_value numeric, p_freight numeric, p_assembly numeric, p_payments jsonb, p_due_date date, p_notes text, p_address uuid, p_confirm boolean)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_uid uuid := auth.uid();
 v_tenant uuid;
 v_customer public.customers%rowtype;
 v_address public.customer_addresses%rowtype;
 v_items_total numeric(14,2);
 v_discount numeric(14,2);
 v_paid numeric(14,2);
 v_total numeric(14,2);
 v_num bigint;
 v_order uuid;
 v_payment jsonb;
 v_item jsonb;
begin
 if v_uid is null or not private.allowed(p_company,p_branch,'orders.write') then
  raise exception 'Sem autorização para emitir pedidos nesta unidade';
 end if;
 select c.tenant_id into v_tenant from public.companies c
 join public.branches b on b.company_id=c.id
 where c.id=p_company and b.id=p_branch and c.active and b.active;
 if v_tenant is null then raise exception 'Empresa ou unidade inválida'; end if;

 if p_seller is distinct from v_uid and not private.allowed(p_company,p_branch,'admin.read') then
  raise exception 'Vendedor não autorizado para esta sessão';
 end if;
 if not exists (
   select 1 from public.user_memberships m join public.profiles pr on pr.id=m.user_id
   where m.user_id=p_seller and m.active and pr.active and m.tenant_id=v_tenant
     and (m.company_id is null or m.company_id=p_company)
     and (m.branch_id is null or m.branch_id=p_branch)
     and m.role in ('seller','cashier','manager','company_admin','tenant_admin')
 ) then raise exception 'Vendedor sem vínculo ativo nesta loja'; end if;

 select * into v_customer from public.customers
 where id=p_customer and company_id=p_company and active;
 if not found then raise exception 'Cliente inexistente ou não autorizado'; end if;
 if p_fulfillment not in ('delivery','pickup') or p_availability not in ('ready','manufacturing','ordered','blocked')
 then raise exception 'Modalidade de atendimento ou disponibilidade inválida'; end if;
 if p_fulfillment='delivery' then
  select * into v_address from public.customer_addresses
  where id=p_address and customer_id=p_customer and company_id=p_company and active;
  if not found then raise exception 'Selecione endereço de entrega ativo'; end if;
 elsif p_address is not null then
  select * into v_address from public.customer_addresses where id=p_address and customer_id=p_customer and company_id=p_company;
  if not found then raise exception 'Endereço não pertence ao cliente'; end if;
 end if;

 if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items)=0 or jsonb_array_length(p_items)>100
 then raise exception 'Informe entre 1 e 100 itens'; end if;
 if jsonb_typeof(p_payments) <> 'array' then raise exception 'Formato de pagamentos inválido'; end if;
 if p_discount_kind not in ('percent','fixed') or p_discount_value is null or p_discount_value<0
 or p_freight is null or p_freight<0 or p_assembly is null or p_assembly<0
 then raise exception 'Desconto ou serviço inválido'; end if;
 if round(p_freight,2)<>p_freight or round(p_assembly,2)<>p_assembly or round(p_discount_value,2)<>p_discount_value
 then raise exception 'Valores monetários devem conter até duas casas decimais'; end if;

 v_items_total:=0;
 for v_item in select value from jsonb_array_elements(p_items)
 loop
  if coalesce(length(trim(v_item->>'name')),0)<2
     or coalesce((v_item->>'quantity')::integer,0)<1
     or coalesce((v_item->>'unit_price')::numeric,-1)<0
     or round((v_item->>'unit_price')::numeric,2)<>(v_item->>'unit_price')::numeric
     or (v_item->>'quantity')::integer>10000 then
    raise exception 'Item inválido';
  end if;
  if v_item ? 'product_id' and v_item->>'product_id' is not null and
     not exists(select 1 from public.products p where p.id=(v_item->>'product_id')::uuid and p.company_id=p_company and p.active)
  then raise exception 'Produto não pertence à empresa'; end if;
  v_items_total:=v_items_total+((v_item->>'quantity')::integer*(v_item->>'unit_price')::numeric);
 end loop;
 if v_items_total>999999999999.99 then raise exception 'Valor do pedido excede o limite'; end if;
 v_items_total:=round(v_items_total,2);
 if p_discount_kind='percent' then
  if p_discount_value>100 then raise exception 'Desconto percentual acima de 100%%'; end if;
  v_discount:=round(v_items_total*p_discount_value/100,2);
 else v_discount:=p_discount_value;
 end if;
 if v_discount>v_items_total then raise exception 'Desconto maior que os produtos'; end if;
 v_total:=v_items_total-v_discount+p_freight+p_assembly;
 v_paid:=0;
 if jsonb_array_length(p_payments)>20 then raise exception 'Muitos pagamentos'; end if;
 for v_payment in select value from jsonb_array_elements(p_payments)
 loop
  if coalesce(v_payment->>'method','') not in ('pix','cash','credit_card','debit_card','bank_transfer')
     or coalesce((v_payment->>'amount')::numeric,0)<=0
     or round((v_payment->>'amount')::numeric,2)<>(v_payment->>'amount')::numeric
     or coalesce((v_payment->>'installments')::integer,1) not between 1 and 24
  then raise exception 'Pagamento inválido'; end if;
  v_paid:=v_paid+(v_payment->>'amount')::numeric;
 end loop;
 if not p_confirm and jsonb_array_length(p_payments)>0 then
  raise exception 'Não registrar recebimentos em pedido rascunho';
 end if;
 if v_paid>v_total then raise exception 'Pagamentos excedem o total'; end if;
 if p_confirm and v_paid<v_total and p_due_date is null then
  raise exception 'Informe o vencimento do saldo a receber'; end if;

 insert into public.order_counters(company_id,last_number) values(p_company,1)
 on conflict(company_id) do update set last_number=public.order_counters.last_number+1
 returning last_number into v_num;

 insert into public.orders(
  tenant_id,company_id,branch_id,customer_id,seller_user_id,order_number,
  commercial_status,financial_status,fulfillment_type,availability_status,address_id,
  products_gross,products_discount,freight,assembly,received_total,due_date,notes,
  customer_snapshot,delivery_address_snapshot,created_by
 ) values (
  v_tenant,p_company,p_branch,p_customer,p_seller,v_num,
  case when p_confirm then 'confirmed' else 'draft' end,
  case when v_paid=v_total then 'paid' when v_paid>0 then 'partial' else 'unpaid' end,
  p_fulfillment,p_availability,p_address,
  v_items_total,v_discount,p_freight,p_assembly,v_paid,p_due_date,p_notes,
  jsonb_build_object('name',v_customer.name,'document',v_customer.document,'mobile',v_customer.mobile,'email',v_customer.email),
  case when p_address is not null then jsonb_build_object('cep',v_address.cep,'street',v_address.street,'number',v_address.number,'neighborhood',v_address.neighborhood,'city',v_address.city,'state',v_address.state,'complement',v_address.complement,'reference_point',v_address.reference_point) else '{}'::jsonb end,
  v_uid
 ) returning id into v_order;

 insert into public.order_items(company_id,order_id,product_id,sku,name,color,size_text,is_showroom,showroom_defects,quantity,unit_price,availability_status)
 select p_company,v_order,
   nullif(x->>'product_id','')::uuid, nullif(x->>'sku',''),
   x->>'name',nullif(x->>'color',''),nullif(x->>'size_text',''),coalesce((x->>'is_showroom')::boolean,false),nullif(btrim(x->>'showroom_defects'),''),(x->>'quantity')::integer,(x->>'unit_price')::numeric,
   case when coalesce(x->>'availability','ready') in ('ready','manufacturing','ordered','blocked')
        then coalesce(x->>'availability','ready') else 'blocked' end
 from jsonb_array_elements(p_items) x;

 if p_confirm then
  insert into public.order_payments(company_id,order_id,method,amount,installments,registered_by)
  select p_company,v_order,x->>'method',(x->>'amount')::numeric,coalesce((x->>'installments')::integer,1),v_uid
  from jsonb_array_elements(p_payments) x;
  if v_paid<v_total then
    insert into public.receivables(company_id,order_id,amount_due,due_date)
    values(p_company,v_order,v_total-v_paid,p_due_date);
  end if;
 end if;
 insert into public.audit_logs(tenant_id,company_id,actor_id,action,entity_type,entity_id,changes)
 values(v_tenant,p_company,v_uid,'order.created','order',v_order,jsonb_build_object('status',case when p_confirm then 'confirmed' else 'draft' end,'total',v_total));
 return v_order;
end;
$function$
;

CREATE OR REPLACE FUNCTION private.sgi_admin_manage_membership(p_membership uuid, p_action text, p_new_role text DEFAULT NULL::text, p_display_name text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE m public.user_memberships%rowtype;v_old text;
BEGIN
 SELECT * INTO m FROM public.user_memberships WHERE id=p_membership FOR UPDATE;
 IF NOT FOUND OR auth.uid() IS NULL OR NOT private.is_tenant_admin(m.tenant_id)
 THEN RAISE EXCEPTION 'Vínculo inexistente ou acesso negado'; END IF;
 IF p_action NOT IN ('activate','deactivate','rename','change_role','remove_unlinked') THEN
   RAISE EXCEPTION 'Ação não autorizada'; END IF;
 IF m.user_id=auth.uid() AND p_action IN ('deactivate','change_role','remove_unlinked') THEN
   RAISE EXCEPTION 'Não é permitido desativar ou rebaixar seu próprio acesso'; END IF;
 IF m.role='tenant_admin' AND p_action IN ('deactivate','change_role','remove_unlinked') AND
    (SELECT count(*) FROM public.user_memberships WHERE tenant_id=m.tenant_id AND role='tenant_admin' AND active)=1
 THEN RAISE EXCEPTION 'O último Master ativo não pode ser removido'; END IF;
 v_old:=m.role;
 CASE p_action
 WHEN 'activate' THEN UPDATE public.user_memberships SET active=true WHERE id=m.id;
 WHEN 'deactivate' THEN UPDATE public.user_memberships SET active=false WHERE id=m.id;
 WHEN 'rename' THEN
  IF length(trim(coalesce(p_display_name,''))) NOT BETWEEN 2 AND 120 THEN RAISE EXCEPTION 'Nome inválido'; END IF;
  UPDATE public.profiles SET display_name=trim(p_display_name),updated_at=now() WHERE id=m.user_id;
 WHEN 'change_role' THEN
  IF p_new_role IS NULL OR p_new_role NOT IN ('tenant_admin','company_admin','manager','seller','cashier','shipping','finance','production','viewer')
     OR (m.company_id IS NULL AND p_new_role<>'tenant_admin')
     OR (m.company_id IS NOT NULL AND p_new_role='tenant_admin') THEN
     RAISE EXCEPTION 'Alteração de escopo administrativo exige novo vínculo autorizado'; END IF;
  UPDATE public.user_memberships SET role=p_new_role WHERE id=m.id;
 WHEN 'remove_unlinked' THEN
  IF m.active THEN RAISE EXCEPTION 'Desative o vínculo antes da remoção'; END IF;
  IF EXISTS(SELECT 1 FROM public.orders WHERE tenant_id=m.tenant_id AND (seller_user_id=m.user_id OR created_by=m.user_id))
    OR EXISTS(SELECT 1 FROM public.audit_logs WHERE tenant_id=m.tenant_id AND actor_id=m.user_id)
    OR EXISTS(SELECT 1 FROM public.customers c WHERE c.tenant_id=m.tenant_id AND c.created_by=m.user_id)
    OR EXISTS(SELECT 1 FROM public.delivery_bookings b WHERE b.tenant_id=m.tenant_id AND b.booked_by=m.user_id)
    OR EXISTS(SELECT 1 FROM public.manifests f WHERE f.tenant_id=m.tenant_id AND f.created_by=m.user_id)
  THEN RAISE EXCEPTION 'Usuário tem histórico; mantenha o vínculo inativo'; END IF;
  DELETE FROM public.user_memberships WHERE id=m.id;
 END CASE;
 INSERT INTO public.audit_logs(tenant_id,company_id,actor_id,action,entity_type,entity_id,changes)
 VALUES(m.tenant_id,m.company_id,auth.uid(),'membership.'||p_action,'user_membership',m.id,
 jsonb_build_object('user_id',m.user_id,'old_role',v_old,'new_role',p_new_role));
END $function$
;

CREATE OR REPLACE FUNCTION private.sgi_assign_user(p_tenant uuid, p_email text, p_company uuid, p_branch uuid, p_role text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_target uuid; v_id uuid;
begin
 if not private.is_tenant_admin(p_tenant) then raise exception 'Somente administrador do grupo'; end if;
 if p_role not in ('tenant_admin','company_admin','manager','seller','cashier','shipping','finance','production','viewer') then raise exception 'Papel inválido'; end if;
 if p_company is null and p_role<>'tenant_admin' then raise exception 'Informe a empresa'; end if;
 if p_company is not null and not exists(select 1 from public.companies where id=p_company and tenant_id=p_tenant and active) then
  raise exception 'Empresa inválida'; end if;
 if p_branch is not null and not exists(select 1 from public.branches where id=p_branch and company_id=p_company and active) then
  raise exception 'Unidade inválida'; end if;
 select id into v_target from auth.users where lower(email)=lower(trim(p_email)) and email_confirmed_at is not null;
 if v_target is null then raise exception 'Usuário não encontrado ou e-mail não confirmado'; end if;
 insert into public.profiles(id,display_name) values(v_target,split_part(lower(p_email),'@',1))
 on conflict(id) do nothing;
 insert into public.user_memberships(user_id,tenant_id,company_id,branch_id,role,active,granted_by)
 values(v_target,p_tenant,p_company,p_branch,p_role,true,auth.uid())
 on conflict do nothing returning id into v_id;
 if v_id is null then
 select id into v_id from public.user_memberships where user_id=v_target and tenant_id=p_tenant and role=p_role
 and company_id is not distinct from p_company and branch_id is not distinct from p_branch;
 update public.user_memberships set active=true,granted_by=auth.uid() where id=v_id;
 end if;
 insert into public.audit_logs(tenant_id,company_id,actor_id,action,entity_type,entity_id,changes)
 values(p_tenant,p_company,auth.uid(),'user.membership_grant','user_membership',v_id,jsonb_build_object('role',p_role));
 return v_id;
end; $function$
;

CREATE OR REPLACE FUNCTION private.sgi_void_draft(p_order uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o public.orders%rowtype;
begin
 select * into o from public.orders where id=p_order for update;
 if not found or o.commercial_status<>'draft' or o.deleted_at is not null or
 not private.allowed(o.company_id,o.branch_id,'orders.cancel') then raise exception 'Apenas rascunhos autorizados podem ser removidos'; end if;
 update public.orders set commercial_status='cancelled',deleted_at=now(),deleted_by=auth.uid(),updated_at=now() where id=p_order;
 insert into public.audit_logs(tenant_id,company_id,actor_id,action,entity_type,entity_id)
 values(o.tenant_id,o.company_id,auth.uid(),'order.draft_void','order',p_order);
end; $function$
;

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
 select * into s from public.delivery_slots where id=p_slot for update;
 if not found or not s.active or s.tenant_id<>o.tenant_id or s.delivery_date<current_date
 or s.reserved>=s.capacity then raise exception 'Data sem disponibilidade'; end if;
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

CREATE OR REPLACE FUNCTION private.sgi_confirm_draft(p_order uuid, p_payments jsonb, p_due_date date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o public.orders%rowtype; p jsonb; v_paid numeric(14,2):=0;
begin
 select * into o from public.orders where id=p_order for update;
 if not found or o.commercial_status<>'draft' or o.deleted_at is not null or
 not private.allowed(o.company_id,o.branch_id,'orders.write') then raise exception 'Rascunho não autorizado'; end if;
 if o.created_by<>auth.uid() and not private.allowed(o.company_id,o.branch_id,'admin.read') then raise exception 'Apenas criador ou gerente pode confirmar'; end if;
 if o.commercial_seller_id is null or o.delivery_lead_business_days is null then raise exception 'Informe vendedor e prazo antes de confirmar'; end if;
 if not exists(select 1 from public.commercial_sellers cs where cs.id=o.commercial_seller_id and cs.company_id=o.company_id and cs.active and (cs.branch_id is null or cs.branch_id=o.branch_id)) then raise exception 'Vendedor comercial inativo ou inválido'; end if;
 if jsonb_typeof(p_payments)<>'array' or jsonb_array_length(p_payments)>20 then raise exception 'Pagamentos inválidos'; end if;
 if o.products_gross<=0 or o.products_discount>o.products_gross then raise exception 'Pedido sem produtos válidos'; end if;
 for p in select value from jsonb_array_elements(p_payments) loop
  if p->>'method' not in ('pix','cash','credit_card','debit_card','bank_transfer')
     or coalesce((p->>'amount')::numeric,0)<=0 or round((p->>'amount')::numeric,2)<>(p->>'amount')::numeric
     or coalesce((p->>'installments')::integer,1) not between 1 and 24 then
       raise exception 'Pagamento inválido';
  end if;
  v_paid:=v_paid+(p->>'amount')::numeric;
 end loop;
 if v_paid>o.grand_total then raise exception 'Valor recebido excede o pedido'; end if;
 if v_paid<o.grand_total and p_due_date is null then raise exception 'Informe vencimento do saldo'; end if;
 insert into public.order_payments(company_id,order_id,method,amount,installments,registered_by)
 select o.company_id,o.id,j->>'method',(j->>'amount')::numeric,coalesce((j->>'installments')::integer,1),auth.uid()
 from jsonb_array_elements(p_payments) j;
 update public.orders
 set commercial_status='confirmed', financial_status=case when v_paid=o.grand_total then 'paid' when v_paid=0 then 'unpaid' else 'partial' end,
 received_total=v_paid,due_date=p_due_date,updated_at=now()
 where id=p_order;
 if v_paid<o.grand_total then
 insert into public.receivables(company_id,order_id,amount_due,due_date)
 values(o.company_id,o.id,o.grand_total-v_paid,p_due_date);
 end if;
 insert into public.audit_logs(tenant_id,company_id,actor_id,action,entity_type,entity_id,changes)
 values(o.tenant_id,o.company_id,auth.uid(),'order.confirmed','order',o.id,jsonb_build_object('total',o.grand_total,'paid',v_paid));
 return p_order;
end; $function$
;

CREATE OR REPLACE FUNCTION private.sgi_dispatch_queue(p_company uuid, p_page integer DEFAULT 0, p_size integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_total bigint:=0;v_rows jsonb:='[]'::jsonb;
begin
 if auth.uid() is null or p_page is null or p_page<0 or p_size is null or p_size not between 1 and 50 then
  raise exception 'Consulta inválida';
 end if;
 if not exists(
  select 1 from public.branches br
  where br.company_id=p_company and private.allowed(p_company,br.id,'shipping.consult')
 ) then raise exception 'Sem autorização para consultar a expedição'; end if;

 select count(*) into v_total from public.orders o
 where o.company_id=p_company and o.commercial_status='confirmed' and o.deleted_at is null
 and (o.fulfillment_type='delivery' or (o.fulfillment_type='pickup' and o.assembly>0))
 and private.allowed(o.company_id,o.branch_id,'shipping.consult')
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
      where private.sgi_location_key(a.city)=private.sgi_location_key(o.delivery_address_snapshot->>'city')
        and private.sgi_location_key(a.neighborhood)=private.sgi_location_key(o.delivery_address_snapshot->>'neighborhood')
     ) then 'region'
     when not exists (
      select 1 from public.delivery_slots s
      join public.delivery_regions r on r.id=s.region_id and r.active
      join public.delivery_region_areas a on a.region_id=r.id
      join public.logistics_pool_branches pb on pb.pool_id=s.pool_id and pb.branch_id=o.branch_id
      where s.tenant_id=o.tenant_id and s.active
        and s.delivery_date between current_date and current_date+45
        and s.reserved<s.capacity
        and private.sgi_location_key(a.city)=private.sgi_location_key(o.delivery_address_snapshot->>'city')
        and private.sgi_location_key(a.neighborhood)=private.sgi_location_key(o.delivery_address_snapshot->>'neighborhood')
     ) then 'capacity'
     else 'ready'
    end as stage
  from public.orders o
  where o.company_id=p_company and o.commercial_status='confirmed' and o.deleted_at is null
    and (o.fulfillment_type='delivery' or (o.fulfillment_type='pickup' and o.assembly>0))
    and private.allowed(o.company_id,o.branch_id,'shipping.consult')
    and not exists(select 1 from public.delivery_bookings b where b.order_id=o.id and b.status<>'cancelled')
  order by o.created_at desc limit p_size offset (p_page*p_size)
 ) q;
 return jsonb_build_object('total',v_total,'rows',v_rows);
end
$function$
;

CREATE OR REPLACE FUNCTION private.sgi_suggest_delivery_dates(p_order uuid)
 RETURNS TABLE(slot_id uuid, deliver_on date, region_name text, available integer, capacity integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o public.orders%rowtype;
begin
 select * into o from public.orders where id=p_order;
 if not found or not private.allowed(o.company_id,o.branch_id,'shipping.consult') then raise exception 'Acesso negado'; end if;
 return query
 select s.id,s.delivery_date,r.name,(s.capacity-s.reserved),s.capacity
 from public.delivery_slots s
 join public.delivery_regions r on r.id=s.region_id and r.active
 join public.delivery_region_areas a on a.region_id=r.id
 join public.logistics_pool_branches m on m.pool_id=s.pool_id and m.branch_id=o.branch_id
 where s.tenant_id=o.tenant_id and s.active and s.delivery_date>=current_date and s.delivery_date<=current_date+45
 and private.sgi_location_key(a.city)=private.sgi_location_key(o.delivery_address_snapshot->>'city')
 and private.sgi_location_key(a.neighborhood)=private.sgi_location_key(o.delivery_address_snapshot->>'neighborhood')
 and s.reserved<s.capacity
 order by s.delivery_date asc
 limit 12;
end; $function$
;

CREATE OR REPLACE FUNCTION private.sgi_suggest_distance_slots(p_order uuid)
 RETURNS TABLE(slot_id uuid, deliver_on date, region_name text, available integer, capacity integer, approx_km numeric, signal text, observation text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE o public.orders%rowtype;
BEGIN
 SELECT * INTO o FROM public.orders WHERE id=p_order;
 IF NOT FOUND OR auth.uid() IS NULL OR NOT private.allowed(o.company_id,o.branch_id,'shipping.consult')
 THEN RAISE EXCEPTION 'Acesso negado ao pedido'; END IF;
 RETURN QUERY
 WITH destination AS (
  SELECT g.lat,g.lon FROM public.sgi_postcode_geocodes g WHERE g.tenant_id=o.tenant_id
   AND g.cep=regexp_replace(coalesce(o.delivery_address_snapshot->>'cep',''),'[^0-9]','','g')
 ),
 matched AS (
  SELECT s.id,s.delivery_date,r.name,s.capacity,s.reserved,s.pool_id
  FROM public.delivery_slots s
  JOIN public.delivery_regions r ON r.id=s.region_id AND r.active
  JOIN public.delivery_region_areas a ON a.region_id=r.id
  JOIN public.logistics_pool_branches pb ON pb.pool_id=s.pool_id AND pb.branch_id=o.branch_id
  WHERE s.tenant_id=o.tenant_id AND s.active AND s.delivery_date BETWEEN current_date AND current_date+45
   AND s.reserved<s.capacity
   AND private.sgi_location_key(a.city)=private.sgi_location_key(o.delivery_address_snapshot->>'city')
   AND private.sgi_location_key(a.neighborhood)=private.sgi_location_key(o.delivery_address_snapshot->>'neighborhood')
 )
 SELECT m.id,m.delivery_date,m.name,(m.capacity-m.reserved)::integer,m.capacity,
  round(d.nearest_km::numeric,1) AS approx_km,
  CASE WHEN d.nearest_km IS NULL THEN 'regional'
       WHEN d.nearest_km<=4 THEN 'nearby'
       WHEN d.nearest_km<=10 THEN 'moderate' ELSE 'far' END,
  CASE WHEN d.nearest_km IS NULL THEN 'Região atendida; sem coordenadas suficientes para estimar a proximidade.'
       ELSE 'Distância em linha reta aproximada entre CEPs; não é quilometragem rodoviária.' END
 FROM matched m
 LEFT JOIN LATERAL (
  SELECT min(private.sgi_haversine_km(ref.lat,ref.lon,ge.lat,ge.lon)) AS nearest_km
  FROM destination ref
  JOIN public.delivery_bookings b ON b.slot_id IN (
    SELECT sx.id FROM public.delivery_slots sx WHERE sx.pool_id=m.pool_id AND sx.delivery_date=m.delivery_date)
    AND b.status IN ('scheduled','loaded','in_route')
  JOIN public.orders prior_order ON prior_order.id=b.order_id AND prior_order.tenant_id=o.tenant_id
  JOIN public.sgi_postcode_geocodes ge ON ge.tenant_id=o.tenant_id
    AND ge.cep=regexp_replace(coalesce(prior_order.delivery_address_snapshot->>'cep',''),'[^0-9]','','g')
 ) d ON true
 ORDER BY CASE WHEN d.nearest_km IS NULL THEN 1 ELSE 0 END,
          m.delivery_date ASC,d.nearest_km ASC
 LIMIT 12;
END $function$
;

CREATE OR REPLACE FUNCTION private.sgi_create_order_idempotent(p_request uuid, p_company uuid, p_branch uuid, p_customer uuid, p_seller uuid, p_fulfillment text, p_availability text, p_items jsonb, p_discount_kind text, p_discount_value numeric, p_freight numeric, p_assembly numeric, p_payments jsonb, p_due_date date, p_notes text, p_address uuid, p_confirm boolean)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v uuid;v_gross numeric:=0;j jsonb;v_requested_discount numeric;v_max numeric;
begin
 if auth.uid() is null or p_request is null or not private.allowed(p_company,p_branch,'orders.write')
 then raise exception 'Operação não autorizada'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_company::text||':'||auth.uid()::text||':'||p_request::text,0));
 select id into v from public.orders where company_id=p_company and created_by=auth.uid() and client_request_id=p_request;
 if v is not null then return v; end if;
 if not private.allowed(p_company,p_branch,'admin.read') then
  select coalesce(seller_max_discount_pct,0) into v_max from public.sales_policies where company_id=p_company;
  v_max:=coalesce(v_max,0);
  if jsonb_typeof(p_items)<>'array' then raise exception 'Itens inválidos'; end if;
  for j in select value from jsonb_array_elements(p_items) loop
    v_gross:=v_gross + coalesce((j->>'quantity')::numeric,0)*coalesce((j->>'unit_price')::numeric,0);
  end loop;
  if p_discount_kind='percent' then v_requested_discount:=p_discount_value;
  else v_requested_discount:=case when v_gross>0 then p_discount_value*100/v_gross else 101 end;
  end if;
  if v_requested_discount>v_max then raise exception 'Desconto acima do limite para seu perfil; solicite aprovação gerencial'; end if;
 end if;
 if not private.create_order_impl_guard(p_company,p_branch,p_customer) then raise exception 'Sem acesso ao cliente ou à loja do pedido'; end if;
 v:=private.create_order_impl(p_company,p_branch,p_customer,p_seller,p_fulfillment,p_availability,p_items,
 p_discount_kind,p_discount_value,p_freight,p_assembly,p_payments,p_due_date,p_notes,p_address,p_confirm);
 update public.orders set client_request_id=p_request where id=v and company_id=p_company and created_by=auth.uid();
 return v;
end; $function$
;

CREATE OR REPLACE FUNCTION private.sgi_seller_monthly_report(p_company uuid, p_month date)
 RETURNS TABLE(seller_id uuid, seller_name text, order_count bigint, products_gross numeric, products_discount numeric, products_net numeric, legacy_date_count bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if auth.uid() is null or p_month is null or not exists (
  select 1 from public.branches b where b.company_id=p_company and private.allowed(b.company_id,b.id,'report.read')
 ) then raise exception 'Sem acesso ao relatorio'; end if;
 return query
 select coalesce(o.commercial_seller_id,o.seller_user_id),
 coalesce(nullif(cs.display_name,''),nullif(pr.display_name,''),'Vendedor'),
 count(*)::bigint,coalesce(sum(o.products_gross),0)::numeric,coalesce(sum(o.products_discount),0)::numeric,
 coalesce(sum(o.products_gross-o.products_discount),0)::numeric,
 count(*) filter(where o.confirmed_at is null)::bigint
 from public.orders o
 left join public.commercial_sellers cs on cs.id=o.commercial_seller_id
 left join public.profiles pr on pr.id=o.seller_user_id
 where o.company_id=p_company and o.commercial_status='confirmed' and o.deleted_at is null
 and coalesce(o.confirmed_at,o.created_at) >= date_trunc('month',p_month::timestamp)
 and coalesce(o.confirmed_at,o.created_at) < date_trunc('month',p_month::timestamp)+interval '1 month'
 and private.allowed(o.company_id,o.branch_id,'report.read')
 and (o.seller_user_id=auth.uid() or private.allowed(o.company_id,o.branch_id,'admin.read'))
 group by coalesce(o.commercial_seller_id,o.seller_user_id),cs.display_name,pr.display_name
 order by coalesce(sum(o.products_gross-o.products_discount),0) desc;
end $function$
;

CREATE OR REPLACE FUNCTION private.sgi_seller_report(p_company uuid)
 RETURNS TABLE(seller_id uuid, seller_name text, order_count bigint, products_gross numeric, products_discount numeric, products_net numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if auth.uid() is null or not exists(
 select 1 from public.user_memberships m where m.user_id=auth.uid() and m.active
 and (m.company_id=p_company or (m.company_id is null and exists(select 1 from public.companies c where c.id=p_company and c.tenant_id=m.tenant_id)))
 ) then raise exception 'Sem autorização'; end if;
 return query select o.seller_user_id,coalesce(nullif(pr.display_name,''),'Vendedor'),
 count(*)::bigint,sum(o.products_gross)::numeric,sum(o.products_discount)::numeric,
 sum(o.products_gross-o.products_discount)::numeric
 from public.orders o left join public.profiles pr on pr.id=o.seller_user_id
 where o.company_id=p_company and o.commercial_status='confirmed' and o.deleted_at is null
 and private.allowed(o.company_id,o.branch_id,'report.read')
 and (o.seller_user_id=auth.uid() or private.allowed(o.company_id,o.branch_id,'admin.read'))
 group by o.seller_user_id,pr.display_name order by sum(o.products_gross-o.products_discount) desc;
end; $function$
;

CREATE OR REPLACE FUNCTION public.sgi_set_order_commercial_details(p_order uuid, p_commercial_seller uuid, p_lead_days integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o public.orders%rowtype;
begin
 select * into o from public.orders where id=p_order for update;
 if not found or o.deleted_at is not null or not private.allowed(o.company_id,o.branch_id,'orders.write') then raise exception 'Pedido nao autorizado'; end if;
 if o.commercial_status not in ('draft','confirmed') then raise exception 'Pedido cancelado ou encerrado não pode ser alterado'; end if;
 if o.commercial_status<>'draft' and not private.allowed(o.company_id,o.branch_id,'admin.read') then raise exception 'Alterar venda confirmada requer gerente'; end if;
 if o.created_by<>auth.uid() and not private.allowed(o.company_id,o.branch_id,'admin.read') then raise exception 'Apenas criador ou gerente pode editar'; end if;
 if p_lead_days is null or p_lead_days not between 1 and 180 then raise exception 'Prazo invalido'; end if;
 if not exists(select 1 from public.commercial_sellers where id=p_commercial_seller and company_id=o.company_id and active and (branch_id is null or branch_id=o.branch_id))
 then raise exception 'Vendedor comercial invalido'; end if;
 update public.orders set commercial_seller_id=p_commercial_seller,delivery_lead_business_days=p_lead_days,updated_at=now() where id=p_order;
 insert into public.audit_logs(tenant_id,company_id,actor_id,action,entity_type,entity_id,changes)
 values(o.tenant_id,o.company_id,auth.uid(),'order.commercial_details_updated','order',p_order,
 jsonb_build_object('old_seller',o.commercial_seller_id,'new_seller',p_commercial_seller,'old_lead',o.delivery_lead_business_days,'new_lead',p_lead_days));
 return p_order;
end $function$
;

-- O caixa lê apenas os pedidos que criou. Papéis anteriores conservam seu escopo.
alter policy orders_read on public.orders using (
 private.allowed(company_id,branch_id,'orders.read') and
 (created_by=(select auth.uid()) or private.allowed(company_id,branch_id,'orders.read.all'))
);
alter policy delivery_bookings_read on public.delivery_bookings using (
 private.allowed(company_id,branch_id,'orders.read.all')
);
alter table public.orders add column if not exists cancelled_at timestamptz;
alter table public.orders add column if not exists cancelled_by uuid;
alter table public.orders add column if not exists cancellation_reason text;
alter table public.orders add column if not exists refund_reference text;

-- Cancelamento transacional; jamais marca uma devolução não realizada.
create or replace function private.sgi_cancel_confirmed_order(p_order uuid,p_reason text,p_expected_received numeric,p_refund_reference text default null)
returns void language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype;b public.delivery_bookings%rowtype;v_paid numeric;v_reason text:=btrim(coalesce(p_reason,''));v_ref text:=nullif(btrim(coalesce(p_refund_reference,'')),'');
begin
 if auth.uid() is null then raise exception 'Acesso negado'; end if;
 select * into o from public.orders where id=p_order for update;
 if not found or not private.allowed(o.company_id,o.branch_id,'orders.cancel') then raise exception 'Somente administrador autorizado pode cancelar pedidos'; end if;
 if o.commercial_status='cancelled' then return; end if;
 if o.commercial_status<>'confirmed' or o.deleted_at is not null then raise exception 'Somente pedidos confirmados e não encerrados podem ser cancelados'; end if;
 if char_length(v_reason) not between 10 and 1000 then raise exception 'Informe motivo do cancelamento (10 a 1000 caracteres)'; end if;
 select coalesce(sum(amount),0) into v_paid from public.order_payments where order_id=o.id and status='confirmed';
 if v_paid is distinct from o.received_total or p_expected_received is distinct from v_paid then raise exception 'Divergência financeira: confira pagamentos antes de cancelar'; end if;
 if v_paid>0 and (v_ref is null or char_length(v_ref) not between 8 and 250) then raise exception 'Realize o estorno efetivo e informe a referência/comprovante antes de cancelar'; end if;
 if v_paid=0 and v_ref is not null then raise exception 'Pedido sem pagamentos não exige estorno'; end if;
 for b in select * from public.delivery_bookings where order_id=o.id and status<>'cancelled' order by id for update loop
  if b.status<>'scheduled' or exists(select 1 from public.manifest_stops where booking_id=b.id) then
   raise exception 'Pedido com carga, romaneio ou entrega iniciada: resolva a logística antes de cancelar';
  end if;
  update public.delivery_slots set reserved=reserved-1 where id=b.slot_id and reserved>0;
  if not found then raise exception 'Reserva logística inconsistente: revise a capacidade antes de cancelar'; end if;
  update public.delivery_bookings set status='cancelled',delivery_notes=v_reason where id=b.id;
 end loop;
 update public.order_payments set status='reversed' where order_id=o.id and status='confirmed';
 update public.receivables set status='cancelled',amount_due=0 where order_id=o.id and status='open';
 update public.orders set commercial_status='cancelled',financial_status=case when v_paid>0 then 'refunded' else 'unpaid' end,
 received_total=0,due_date=null,cancelled_at=now(),cancelled_by=auth.uid(),cancellation_reason=v_reason,refund_reference=v_ref,updated_at=now()
 where id=o.id;
 insert into public.audit_logs(tenant_id,company_id,actor_id,action,entity_type,entity_id,changes)
 values(o.tenant_id,o.company_id,auth.uid(),'order.cancelled','order',o.id,jsonb_build_object('reason',v_reason,'original_total',o.grand_total,'refunded_amount',v_paid,'refund_reference',v_ref));
end $$;
revoke all on function private.sgi_cancel_confirmed_order(uuid,text,numeric,text) from public,anon;
grant execute on function private.sgi_cancel_confirmed_order(uuid,text,numeric,text) to authenticated;
create or replace function public.sgi_cancel_confirmed_order(p_order uuid,p_reason text,p_expected_received numeric,p_refund_reference text default null)
returns void language sql security invoker set search_path='' as $$
 select private.sgi_cancel_confirmed_order($1,$2,$3,$4)
$$;
revoke all on function public.sgi_cancel_confirmed_order(uuid,text,numeric,text) from public,anon;
grant execute on function public.sgi_cancel_confirmed_order(uuid,text,numeric,text) to authenticated;

create or replace function public.create_order(p_company uuid,p_branch uuid,p_customer uuid,p_seller uuid,p_fulfillment text,p_availability text,p_items jsonb,p_discount_kind text,p_discount_value numeric,p_freight numeric,p_assembly numeric,p_payments jsonb,p_due_date date,p_notes text,p_address uuid,p_confirm boolean)
returns uuid language plpgsql set search_path='' as $$
begin
 if not private.allowed(p_company,p_branch,'orders.legacy') or not private.create_order_impl_guard(p_company,p_branch,p_customer)
 then raise exception 'Use o fluxo de emissão comercial autorizado'; end if;
 return private.create_order_impl(p_company,p_branch,p_customer,p_seller,p_fulfillment,p_availability,p_items,p_discount_kind,p_discount_value,p_freight,p_assembly,p_payments,p_due_date,p_notes,p_address,p_confirm);
end $$;
create or replace function public.sgi_create_order_v2(p_request uuid,p_company uuid,p_branch uuid,p_customer uuid,p_seller uuid,p_fulfillment text,p_availability text,p_items jsonb,p_discount_kind text,p_discount_value numeric,p_freight numeric,p_assembly numeric,p_payments jsonb,p_due_date date,p_notes text,p_address uuid,p_confirm boolean)
returns uuid language plpgsql set search_path='' as $$
begin
 if not private.allowed(p_company,p_branch,'orders.legacy') then raise exception 'Use o fluxo de emissão comercial autorizado'; end if;
 return private.sgi_create_order_idempotent(p_request,p_company,p_branch,p_customer,p_seller,p_fulfillment,p_availability,p_items,p_discount_kind,p_discount_value,p_freight,p_assembly,p_payments,p_due_date,p_notes,p_address,p_confirm);
end $$;
