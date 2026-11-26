-- Registro de condições de peças de mostruário por item, preservando a disponibilidade pronta entrega.
alter table public.order_items add column if not exists is_showroom boolean not null default false;
alter table public.order_items add column if not exists showroom_defects text null;
alter table public.order_items add constraint sgi_showroom_defects_required check (not is_showroom or (showroom_defects is not null and char_length(btrim(showroom_defects)) between 5 and 1000));

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
     and m.role in ('seller','manager','company_admin','tenant_admin')
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

CREATE OR REPLACE FUNCTION private.sgi_update_draft(p_order uuid, p_customer uuid, p_address uuid, p_fulfillment text, p_availability text, p_items jsonb, p_discount_type text, p_discount numeric, p_freight numeric, p_assembly numeric, p_notes text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o public.orders%rowtype;c public.customers%rowtype;a public.customer_addresses%rowtype;
 j jsonb;v_gross numeric(14,2):=0;v_discount numeric(14,2);v_total numeric(14,2);
begin
 select * into o from public.orders where id=p_order for update;
 if not found or o.commercial_status<>'draft' or o.deleted_at is not null or
 not private.allowed(o.company_id,o.branch_id,'orders.write') then raise exception 'Sem acesso ao rascunho'; end if;
 if o.created_by<>auth.uid() and not private.allowed(o.company_id,o.branch_id,'admin.read') then raise exception 'Apenas criador ou gerente pode editar'; end if;
 select * into c from public.customers where id=p_customer and company_id=o.company_id and active
 and private.allowed(company_id,created_branch_id,'people.read');
 if not found then raise exception 'Cliente inacessível'; end if;
 if p_address is not null then
 select * into a from public.customer_addresses where id=p_address and customer_id=p_customer and company_id=o.company_id and active;
 if not found then raise exception 'Endereço inválido'; end if;
 end if;
 if p_fulfillment not in ('pickup','delivery') or p_availability not in ('ready','manufacturing','ordered','blocked')
 or (p_fulfillment='delivery' and p_address is null)
 or p_discount_type not in ('percent','fixed')
 or p_discount<0 or p_freight<0 or p_assembly<0 or round(p_discount,2)<>p_discount
 or round(p_freight,2)<>p_freight or round(p_assembly,2)<>p_assembly
 or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items) not between 1 and 100 then raise exception 'Campos inválidos'; end if;
 for j in select value from jsonb_array_elements(p_items) loop
   if length(trim(coalesce(j->>'name','')))<2 or coalesce((j->>'quantity')::int,0) not between 1 and 10000
   or coalesce((j->>'unit_price')::numeric,-1)<0 or round((j->>'unit_price')::numeric,2)<>(j->>'unit_price')::numeric then raise exception 'Item inválido'; end if;
   if nullif(j->>'product_id','') is not null and
   not exists(select 1 from public.products where id=(j->>'product_id')::uuid and company_id=o.company_id and active)
   then raise exception 'Produto de outra empresa'; end if;
   v_gross:=v_gross+(j->>'quantity')::int*(j->>'unit_price')::numeric;
 end loop;
 v_gross:=round(v_gross,2);
 v_discount:=case when p_discount_type='percent' then round(v_gross*p_discount/100,2) else p_discount end;
 if (p_discount_type='percent' and p_discount>100) or v_discount>v_gross then raise exception 'Desconto inválido'; end if;
 v_total:=v_gross-v_discount+p_freight+p_assembly;
 delete from public.order_items where order_id=p_order;
 insert into public.order_items(company_id,order_id,product_id,sku,name,color,size_text,is_showroom,showroom_defects,quantity,unit_price,availability_status)
 select o.company_id,p_order,nullif(src.item->>'product_id','')::uuid,
 nullif(src.item->>'sku',''),src.item->>'name',nullif(src.item->>'color',''),nullif(src.item->>'size_text',''),coalesce((src.item->>'is_showroom')::boolean,false),nullif(btrim(src.item->>'showroom_defects'),'') ,
 (src.item->>'quantity')::int,(src.item->>'unit_price')::numeric,
 case when coalesce(src.item->>'availability','ready') in ('ready','manufacturing','ordered','blocked')
 then coalesce(src.item->>'availability','ready') else 'blocked' end
 from jsonb_array_elements(p_items) as src(item);
 update public.orders set customer_id=p_customer,address_id=p_address,
 fulfillment_type=p_fulfillment,availability_status=p_availability,
 products_gross=v_gross,products_discount=v_discount,freight=p_freight,assembly=p_assembly,
 notes=p_notes,updated_at=now(),
 customer_snapshot=jsonb_build_object('name',c.name,'document',c.document,'mobile',c.mobile,'email',c.email),
 delivery_address_snapshot=case when p_address is null then '{}'::jsonb else
 jsonb_build_object('cep',a.cep,'street',a.street,'number',a.number,'neighborhood',a.neighborhood,
 'city',a.city,'state',a.state,'complement',a.complement,'reference_point',a.reference_point) end
 where id=p_order;
 insert into public.audit_logs(tenant_id,company_id,actor_id,action,entity_type,entity_id,changes)
 values(o.tenant_id,o.company_id,auth.uid(),'order.draft_update','order',p_order,jsonb_build_object('new_total',v_total));
 return p_order;
end; $function$
;
