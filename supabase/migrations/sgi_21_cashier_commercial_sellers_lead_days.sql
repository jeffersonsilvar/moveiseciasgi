-- SGI Black Friday: vendedores comerciais independentes do login e prazo em dias uteis.
-- Migration aditiva: preserva pedidos existentes, vendedor legado e data de vencimento.
create table if not exists public.commercial_sellers (
 id uuid primary key default gen_random_uuid(),
 tenant_id uuid not null references public.tenants(id),
 company_id uuid not null references public.companies(id),
 branch_id uuid null references public.branches(id),
 display_name text not null check (char_length(btrim(display_name)) between 2 and 120),
 active boolean not null default true,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create index if not exists commercial_sellers_company_idx on public.commercial_sellers(company_id,active,display_name);
alter table public.commercial_sellers enable row level security;
revoke all on public.commercial_sellers from anon, authenticated;
alter table public.orders add column if not exists commercial_seller_id uuid null references public.commercial_sellers(id);
alter table public.orders add column if not exists delivery_lead_business_days integer null check (delivery_lead_business_days between 1 and 180);
create index if not exists orders_commercial_seller_idx on public.orders(commercial_seller_id);

-- O acesso comercial ocorre exclusivamente por RPC validada no servidor.
create or replace function public.sgi_commercial_sellers(p_company uuid,p_branch uuid default null,p_include_inactive boolean default false)
returns table(id uuid,display_name text,branch_id uuid,active boolean)
language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not exists (
   select 1 from public.branches b where b.company_id=p_company
     and (p_branch is null or b.id=p_branch)
     and private.allowed(b.company_id,b.id,'orders.read')
 ) then raise exception 'Acesso negado aos vendedores'; end if;
 return query select s.id,s.display_name,s.branch_id,s.active from public.commercial_sellers s
 where s.company_id=p_company
   and (p_include_inactive or s.active)
   and (p_branch is null or s.branch_id is null or s.branch_id=p_branch)
   and (s.branch_id is null or private.allowed(s.company_id,s.branch_id,'orders.read'))
 order by s.display_name;
end $$;
revoke all on function public.sgi_commercial_sellers(uuid,uuid,boolean) from public,anon;
grant execute on function public.sgi_commercial_sellers(uuid,uuid,boolean) to authenticated;

create or replace function public.sgi_save_commercial_seller(p_company uuid,p_branch uuid,p_name text,p_id uuid default null,p_active boolean default true)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid;v_tenant uuid;v_old public.commercial_sellers%rowtype;
begin
 if auth.uid() is null or not exists (
   select 1 from public.branches b where b.company_id=p_company
   and (p_branch is null or b.id=p_branch)
   and private.allowed(b.company_id,b.id,'admin.read')
 ) then raise exception 'Somente gestores podem cadastrar vendedores'; end if;
 if length(btrim(coalesce(p_name,''))) not between 2 and 120 then raise exception 'Nome inválido'; end if;
 select tenant_id into v_tenant from public.companies where id=p_company and active;
 if v_tenant is null then raise exception 'Empresa inválida'; end if;
 if p_id is null then
  insert into public.commercial_sellers(tenant_id,company_id,branch_id,display_name,active)
  values(v_tenant,p_company,p_branch,btrim(p_name),p_active) returning id into v_id;
 else
  select * into v_old from public.commercial_sellers where id=p_id and company_id=p_company for update;
  if not found then raise exception 'Vendedor inexistente'; end if;
  if v_old.branch_id is not null and not private.allowed(p_company,v_old.branch_id,'admin.read') then raise exception 'Sem acesso a esta loja'; end if;
  update public.commercial_sellers set display_name=btrim(p_name),branch_id=p_branch,active=p_active,updated_at=now()
  where id=p_id returning id into v_id;
 end if;
 insert into public.audit_logs(tenant_id,company_id,actor_id,action,entity_type,entity_id,changes)
 values(v_tenant,p_company,auth.uid(),case when p_id is null then 'commercial_seller.created' else 'commercial_seller.updated' end,
 'commercial_seller',v_id,jsonb_build_object('name',btrim(p_name),'branch',p_branch,'active',p_active));
 return v_id;
end $$;
revoke all on function public.sgi_save_commercial_seller(uuid,uuid,text,uuid,boolean) from public,anon;
grant execute on function public.sgi_save_commercial_seller(uuid,uuid,text,uuid,boolean) to authenticated;

-- Operacao atomica: gera pedido original e associa vendedor/prazo na mesma transacao.
-- O vendedor legado passa a representar o operador logado, sem transferir credito comercial.
create or replace function public.sgi_create_order_cashier(
 p_request uuid,p_company uuid,p_branch uuid,p_customer uuid,p_commercial_seller uuid,p_lead_days integer,
 p_fulfillment text,p_availability text,p_items jsonb,p_discount_kind text,p_discount_value numeric,
 p_freight numeric,p_assembly numeric,p_payments jsonb,p_due_date date,p_notes text,p_address uuid,p_confirm boolean
) returns uuid language plpgsql security definer set search_path='' as $$
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
  p_discount_kind,p_discount_value,p_freight,p_assembly,p_payments,p_due_date,p_notes,p_address,p_confirm);
 select * into v_old from public.orders where id=v_order for update;
 if v_old.commercial_seller_id is not null and (v_old.commercial_seller_id<>p_commercial_seller or v_old.delivery_lead_business_days<>p_lead_days)
 then raise exception 'Pedido ja emitido com outros dados comerciais'; end if;
 update public.orders set commercial_seller_id=p_commercial_seller,delivery_lead_business_days=p_lead_days where id=v_order;
 insert into public.audit_logs(tenant_id,company_id,actor_id,action,entity_type,entity_id,changes)
 values(v_old.tenant_id,p_company,auth.uid(),'order.cashier_attribution','order',v_order,
 jsonb_build_object('commercial_seller',p_commercial_seller,'delivery_lead_business_days',p_lead_days,'operator',auth.uid()));
 return v_order;
end $$;
revoke all on function public.sgi_create_order_cashier(uuid,uuid,uuid,uuid,uuid,integer,text,text,jsonb,text,numeric,numeric,numeric,jsonb,date,text,uuid,boolean) from public,anon;
grant execute on function public.sgi_create_order_cashier(uuid,uuid,uuid,uuid,uuid,integer,text,text,jsonb,text,numeric,numeric,numeric,jsonb,date,text,uuid,boolean) to authenticated;

create or replace function public.sgi_set_order_commercial_details(p_order uuid,p_commercial_seller uuid,p_lead_days integer)
returns uuid language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype;
begin
 select * into o from public.orders where id=p_order for update;
 if not found or o.deleted_at is not null or not private.allowed(o.company_id,o.branch_id,'orders.write') then raise exception 'Pedido nao autorizado'; end if;
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
end $$;
revoke all on function public.sgi_set_order_commercial_details(uuid,uuid,integer) from public,anon;
grant execute on function public.sgi_set_order_commercial_details(uuid,uuid,integer) to authenticated;

-- Relatorio com novas atribuicoes e suporte a pedidos legados.
create or replace function private.sgi_seller_monthly_report(p_company uuid,p_month date)
returns table(seller_id uuid,seller_name text,order_count bigint,products_gross numeric,products_discount numeric,products_net numeric,legacy_date_count bigint)
language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or p_month is null or not exists (
  select 1 from public.branches b where b.company_id=p_company and private.allowed(b.company_id,b.id,'orders.read')
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
 and private.allowed(o.company_id,o.branch_id,'orders.read')
 and (o.seller_user_id=auth.uid() or private.allowed(o.company_id,o.branch_id,'admin.read'))
 group by coalesce(o.commercial_seller_id,o.seller_user_id),cs.display_name,pr.display_name
 order by coalesce(sum(o.products_gross-o.products_discount),0) desc;
end $$;
