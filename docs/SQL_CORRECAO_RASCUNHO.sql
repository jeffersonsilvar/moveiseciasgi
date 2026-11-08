-- Documentação de função corrigida; a migração incremental sgi_15 já foi aplicada no Supabase em 08/11/2026.
-- SGI · Correção transacional da edição de rascunho.
-- Evita conflito entre variável PL/pgSQL 'j' e alias JSON do INSERT.
create or replace function private.sgi_update_draft(
 p_order uuid,p_customer uuid,p_address uuid,p_fulfillment text,p_availability text,
 p_items jsonb,p_discount_type text,p_discount numeric,p_freight numeric,p_assembly numeric,p_notes text
) returns uuid language plpgsql security definer set search_path='' as $$
declare
 o public.orders%rowtype;
 c public.customers%rowtype;
 a public.customer_addresses%rowtype;
 v_item jsonb;
 v_gross numeric(14,2):=0;
 v_discount numeric(14,2);
 v_total numeric(14,2);
begin
 select * into o from public.orders where id=p_order for update;
 if not found or o.commercial_status<>'draft' or o.deleted_at is not null or
 not private.allowed(o.company_id,o.branch_id,'orders.write') then
   raise exception 'Sem acesso ao rascunho';
 end if;
 if o.created_by<>auth.uid() and not private.allowed(o.company_id,o.branch_id,'admin.read') then
   raise exception 'Apenas criador ou gerente pode editar';
 end if;
 select * into c from public.customers
 where id=p_customer and company_id=o.company_id and active
   and private.allowed(company_id,created_branch_id,'people.read');
 if not found then raise exception 'Cliente inacessível'; end if;
 if p_address is not null then
   select * into a from public.customer_addresses
   where id=p_address and customer_id=p_customer and company_id=o.company_id and active;
   if not found then raise exception 'Endereço inválido'; end if;
 end if;
 if p_fulfillment not in ('pickup','delivery')
 or p_availability not in ('ready','manufacturing','ordered','blocked')
 or (p_fulfillment='delivery' and p_address is null)
 or p_discount_type not in ('percent','fixed')
 or p_discount is null or p_freight is null or p_assembly is null
 or p_discount<0 or p_freight<0 or p_assembly<0
 or round(p_discount,2)<>p_discount
 or round(p_freight,2)<>p_freight or round(p_assembly,2)<>p_assembly
 or jsonb_typeof(p_items)<>'array'
 or jsonb_array_length(p_items) not between 1 and 100 then
   raise exception 'Campos do pedido inválidos';
 end if;
 for v_item in select value from jsonb_array_elements(p_items)
 loop
   if length(trim(coalesce(v_item->>'name','')))<2
   or coalesce((v_item->>'quantity')::int,0) not between 1 and 10000
   or coalesce((v_item->>'unit_price')::numeric,-1)<0
   or round((v_item->>'unit_price')::numeric,2)<>(v_item->>'unit_price')::numeric then
     raise exception 'Item inválido';
   end if;
   if nullif(v_item->>'product_id','') is not null
   and not exists(select 1 from public.products
      where id=(v_item->>'product_id')::uuid and company_id=o.company_id and active)
   then raise exception 'Produto de outra empresa'; end if;
   v_gross:=v_gross+(v_item->>'quantity')::int*(v_item->>'unit_price')::numeric;
 end loop;
 v_gross:=round(v_gross,2);
 v_discount:=case when p_discount_type='percent' then round(v_gross*p_discount/100,2) else p_discount end;
 if (p_discount_type='percent' and p_discount>100) or v_discount>v_gross then
   raise exception 'Desconto inválido';
 end if;
 v_total:=v_gross-v_discount+p_freight+p_assembly;
 -- A atualização inteira é uma única transação: em caso de falha, o banco reverte itens e totais.
 delete from public.order_items where order_id=p_order;
 insert into public.order_items(
   company_id,order_id,product_id,sku,name,color,quantity,unit_price,availability_status
 )
 select o.company_id,p_order,nullif(src.item->>'product_id','')::uuid,
   nullif(src.item->>'sku',''),src.item->>'name',nullif(src.item->>'color',''),
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
 values(o.tenant_id,o.company_id,auth.uid(),'order.draft_update','order',p_order,
 jsonb_build_object('new_total',v_total));
 return p_order;
end;
$$;
revoke all on function private.sgi_update_draft(uuid,uuid,uuid,text,text,jsonb,text,numeric,numeric,numeric,text) from public,anon;
grant execute on function private.sgi_update_draft(uuid,uuid,uuid,text,text,jsonb,text,numeric,numeric,numeric,text) to authenticated;
