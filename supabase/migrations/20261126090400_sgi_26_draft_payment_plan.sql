-- Persist intended payment terms separately from confirmed financial movements.
alter table public.orders add column if not exists draft_payments jsonb not null default '[]'::jsonb;
alter table public.orders add column if not exists draft_due_date date;
create or replace function private.sgi_save_draft_payment_plan(p_order uuid,p_payments jsonb,p_due_date date)
returns void language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype; j jsonb; v_sum numeric:=0; v_amount numeric; v_inst int; v_plan jsonb:='[]'::jsonb;
begin
 select * into o from public.orders where id=p_order for update;
 if not found or auth.uid() is null or o.commercial_status<>'draft' or o.deleted_at is not null
 or not private.allowed(o.company_id,o.branch_id,'orders.write')
 or (o.created_by is distinct from auth.uid() and not private.allowed(o.company_id,o.branch_id,'admin.read'))
 then raise exception 'Rascunho não autorizado'; end if;
 if p_payments is null or jsonb_typeof(p_payments)<>'array' then raise exception 'Pagamentos inválidos'; end if;
 if jsonb_array_length(p_payments)>20 then raise exception 'Máximo de 20 pagamentos'; end if;
 for j in select value from jsonb_array_elements(p_payments) loop
   if jsonb_typeof(j)<>'object' or coalesce(j->>'method','') not in ('pix','cash','credit_card','debit_card','bank_transfer')
   then raise exception 'Forma de pagamento inválida'; end if;
   v_amount:=coalesce((j->>'amount')::numeric,0);
   v_inst:=coalesce((j->>'installments')::int,1);
   if v_amount<=0 or v_amount>o.grand_total or round(v_amount,2)<>v_amount or v_inst not between 1 and 24 then raise exception 'Pagamento inválido'; end if;
   v_sum:=v_sum+v_amount;
   v_plan:=v_plan||jsonb_build_array(jsonb_build_object('method',j->>'method','amount',v_amount,'installments',case when j->>'method'='credit_card' then v_inst else 1 end));
 end loop;
 if v_sum>o.grand_total then raise exception 'Pagamentos excedem o total'; end if;
 update public.orders set draft_payments=v_plan,draft_due_date=case when v_sum<o.grand_total then p_due_date else null end,updated_at=now() where id=o.id;
 insert into public.audit_logs(tenant_id,company_id,actor_id,action,entity_type,entity_id,changes)
 values(o.tenant_id,o.company_id,auth.uid(),'order.draft_payment_plan','order',o.id,jsonb_build_object('planned_total',v_sum,'payment_count',jsonb_array_length(v_plan)));
end $$;
revoke all on function private.sgi_save_draft_payment_plan(uuid,jsonb,date) from public,anon,authenticated;
grant execute on function private.sgi_save_draft_payment_plan(uuid,jsonb,date) to authenticated;
CREATE OR REPLACE FUNCTION private.sgi_create_order_cashier(p_request uuid, p_company uuid, p_branch uuid, p_customer uuid, p_commercial_seller uuid, p_lead_days integer, p_fulfillment text, p_availability text, p_items jsonb, p_discount_kind text, p_discount_value numeric, p_freight numeric, p_assembly numeric, p_payments jsonb, p_due_date date, p_notes text, p_address uuid, p_confirm boolean)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_order uuid;v_seller public.commercial_sellers%rowtype;v_old public.orders%rowtype;
begin
 if auth.uid() is null or not private.allowed(p_company,p_branch,'orders.write') then raise exception 'Sem acesso para emitir pedidos'; end if;
 if p_lead_days is null or p_lead_days not between 1 and 180 then raise exception 'Prazo deve ser de 1 a 180 dias uteis'; end if;
 select * into v_seller from public.commercial_sellers
 where id=p_commercial_seller and company_id=p_company and active
 and (branch_id is null or branch_id=p_branch);
 if not found then raise exception 'Selecione vendedor ativo da loja'; end if;
 v_order:=private.sgi_create_order_idempotent(
  p_request,p_company,p_branch,p_customer,auth.uid(),p_fulfillment,p_availability,p_items,
  p_discount_kind,p_discount_value,p_freight,p_assembly,case when p_confirm then p_payments else '[]'::jsonb end,case when p_confirm then p_due_date else null end,p_notes,p_address,p_confirm);
 select * into v_old from public.orders where id=v_order for update;
 if v_old.commercial_seller_id is not null and (v_old.commercial_seller_id<>p_commercial_seller or v_old.delivery_lead_business_days<>p_lead_days)
 then raise exception 'Pedido ja emitido com outros dados comerciais'; end if;
 if v_old.commercial_seller_id is not null then return v_order; end if;
 update public.orders set commercial_seller_id=p_commercial_seller,delivery_lead_business_days=p_lead_days where id=v_order;
 insert into public.audit_logs(tenant_id,company_id,actor_id,action,entity_type,entity_id,changes)
 values(v_old.tenant_id,p_company,auth.uid(),'order.cashier_attribution','order',v_order,
 jsonb_build_object('commercial_seller',p_commercial_seller,'delivery_lead_business_days',p_lead_days,'operator',auth.uid()));
 if not p_confirm then perform private.sgi_save_draft_payment_plan(v_order,p_payments,p_due_date); end if;
 return v_order;
end $function$
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
 received_total=v_paid,due_date=p_due_date,draft_payments='[]'::jsonb,draft_due_date=null,updated_at=now()
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
CREATE OR REPLACE FUNCTION public.sgi_save_draft_cashier(p_order uuid, p_customer uuid, p_address uuid, p_fulfillment text, p_availability text, p_items jsonb, p_discount_type text, p_discount numeric, p_freight numeric, p_assembly numeric, p_notes text, p_commercial_seller uuid, p_lead_days integer, p_confirm boolean, p_payments jsonb, p_due_date date)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
 perform public.sgi_update_draft(p_order,p_customer,p_address,p_fulfillment,p_availability,p_items,p_discount_type,p_discount,p_freight,p_assembly,p_notes);
 perform public.sgi_set_order_commercial_details(p_order,p_commercial_seller,p_lead_days);
 if p_confirm then perform public.sgi_confirm_draft(p_order,p_payments,p_due_date);
 else perform private.sgi_save_draft_payment_plan(p_order,p_payments,p_due_date); end if;
 return p_order;
end $function$
;
