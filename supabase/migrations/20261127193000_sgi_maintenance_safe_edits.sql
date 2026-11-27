-- Audited edits without reallocating reservations.
create or replace function private.sgi_edit_manual_delivery(p_booking uuid,p_company uuid,p_expected jsonb,p_date date,p_manual jsonb,p_reason text)
returns uuid language plpgsql security definer set search_path='' as $$
declare b public.delivery_bookings%rowtype; v jsonb; v_after jsonb; sid uuid; sn text; k text; lim int; reason text:=btrim(coalesce(p_reason,''));
begin
 if auth.uid() is null or length(reason) not between 5 and 500 then raise exception 'Informe motivo de 5 a 500 caracteres';end if;
 select * into b from public.delivery_bookings where id=p_booking and company_id=p_company for update;
 if not found or not private.allowed(b.company_id,b.branch_id,'shipping.write') or b.order_id is not null or b.status<>'scheduled' or exists(select 1 from public.manifest_stops where booking_id=b.id) then raise exception 'Somente entrega avulsa agendada, sem romaneio, pode ser editada';end if;
 if b.manual_order is distinct from p_expected or b.delivery_date is distinct from p_date then raise exception 'Entrega alterada por outro operador. Reabra a edição';end if;
 if p_manual is null or jsonb_typeof(p_manual)<>'object' or octet_length(p_manual::text)>12000 or p_manual->>'released' is distinct from 'true' then raise exception 'Confira os dados e confirme a liberação';end if;
 for k,lim in select * from (values ('reference',80),('customer',150),('products',3000),('city',100),('neighborhood',100),('street',180),('number',40),('phone',40),('notes',1000)) x(k,lim) loop
  if length(btrim(coalesce(p_manual->>k,'')))>lim or (k in ('reference','customer','products','city','neighborhood') and length(btrim(coalesce(p_manual->>k,'')))<case when k='reference' then 1 else 2 end) then raise exception 'Campo inválido: %',k;end if;
 end loop;
 if coalesce(p_manual->>'cep','')<>'' and regexp_replace(p_manual->>'cep','[^0-9]','','g')!~'^[0-9]{8}$' then raise exception 'CEP inválido';end if;
 -- Historical seller remains valid when unchanged; any replacement must be active and scoped.
 if nullif(p_manual->>'seller_id','') is not distinct from nullif(b.manual_order->>'seller_id','') and p_manual->>'seller' is not distinct from b.manual_order->>'seller' then
  sn:=b.manual_order->>'seller';
 else
  select cs.id,cs.display_name into sid,sn from public.commercial_sellers cs where cs.id::text=p_manual->>'seller_id' and cs.tenant_id=b.tenant_id and cs.company_id=b.company_id and cs.active and (cs.branch_id is null or cs.branch_id=b.branch_id) for share;
  if not found then raise exception 'Vendedor inválido, inativo ou de outra loja';end if;
 end if;
 v:=b.manual_order||jsonb_build_object('reference',btrim(p_manual->>'reference'),'customer',btrim(p_manual->>'customer'),'seller',sn,'seller_id',case when sid is null then b.manual_order->'seller_id' else to_jsonb(sid) end,'products',btrim(p_manual->>'products'),'city',btrim(p_manual->>'city'),'neighborhood',btrim(p_manual->>'neighborhood'),'cep',regexp_replace(coalesce(p_manual->>'cep',''),'[^0-9]','','g'),'street',btrim(coalesce(p_manual->>'street','')),'number',btrim(coalesce(p_manual->>'number','')),'phone',btrim(coalesce(p_manual->>'phone','')),'notes',coalesce(p_manual->>'notes',''),'released',true);
 update public.delivery_bookings set manual_order=v,geolocation=case when (v->>'cep',v->>'street',v->>'number',v->>'city',v->>'neighborhood') is distinct from (b.manual_order->>'cep',b.manual_order->>'street',b.manual_order->>'number',b.manual_order->>'city',b.manual_order->>'neighborhood') then null else geolocation end where id=b.id returning manual_order into v_after;
 if v_after is distinct from b.manual_order then
  insert into public.audit_logs(tenant_id,company_id,actor_id,action,entity_type,entity_id,changes) values(b.tenant_id,b.company_id,auth.uid(),'smart_delivery.edited','delivery_booking',b.id,jsonb_build_object('date',b.delivery_date,'reason',reason,'before',b.manual_order,'after',v_after));
 end if;
 return b.id;
end $$;
create or replace function public.sgi_edit_manual_delivery(p_booking uuid,p_company uuid,p_expected jsonb,p_date date,p_manual jsonb,p_reason text) returns uuid language sql set search_path='' as $$select private.sgi_edit_manual_delivery($1,$2,$3,$4,$5,$6)$$;
revoke all on function private.sgi_edit_manual_delivery(uuid,uuid,jsonb,date,jsonb,text),public.sgi_edit_manual_delivery(uuid,uuid,jsonb,date,jsonb,text) from public,anon,authenticated;
grant execute on function private.sgi_edit_manual_delivery(uuid,uuid,jsonb,date,jsonb,text),public.sgi_edit_manual_delivery(uuid,uuid,jsonb,date,jsonb,text) to authenticated;

-- Master-only maintenance. Keep existing IDs and never move a unit across companies.
create or replace function private.sgi_edit_company(p_id uuid,p_expected jsonb,p_legal text,p_trade text,p_cnpj text,p_reason text) returns uuid language plpgsql security definer set search_path='' as $$
declare c public.companies%rowtype; new_c public.companies%rowtype; r text:=btrim(coalesce(p_reason,'')); cn text:=nullif(btrim(coalesce(p_cnpj,'')),'');
begin
 select * into c from public.companies where id=p_id for update;
 if not found or auth.uid() is null or not private.is_tenant_admin(c.tenant_id) or not c.active then raise exception 'Acesso negado ou empresa inativa';end if;
 if p_expected is distinct from jsonb_build_object('legal_name',c.legal_name,'trade_name',c.trade_name,'cnpj',c.cnpj) then raise exception 'Cadastro alterado. Atualize a tela';end if;
 if length(btrim(coalesce(p_legal,''))) not between 3 and 200 or length(btrim(coalesce(p_trade,''))) not between 2 and 120 or (cn is not null and cn!~'^[0-9]{14}$') or length(r) not between 5 and 500 then raise exception 'Dados ou motivo inválidos';end if;
 if cn is distinct from c.cnpj and (exists(select 1 from public.orders where company_id=c.id) or exists(select 1 from public.delivery_bookings where company_id=c.id)) then raise exception 'CNPJ de empresa com movimentação não pode ser substituído por este formulário';end if;
 update public.companies set legal_name=btrim(p_legal),trade_name=btrim(p_trade),cnpj=cn where id=c.id returning * into new_c;
 insert into public.audit_logs(tenant_id,company_id,actor_id,action,entity_type,entity_id,changes) values(c.tenant_id,c.id,auth.uid(),'company.edited','company',c.id,jsonb_build_object('reason',r,'before',to_jsonb(c),'after',to_jsonb(new_c)));
 return c.id;
end $$;
create or replace function private.sgi_edit_branch(p_id uuid,p_expected text,p_name text,p_reason text) returns uuid language plpgsql security definer set search_path='' as $$
declare b public.branches%rowtype; r text:=btrim(coalesce(p_reason,''));
begin
 select * into b from public.branches where id=p_id for update;
 if not found or auth.uid() is null or not private.is_tenant_admin(b.tenant_id) or not b.active then raise exception 'Acesso negado ou unidade inativa';end if;
 if b.name is distinct from p_expected then raise exception 'Cadastro alterado. Atualize a tela';end if;
 if length(btrim(coalesce(p_name,''))) not between 2 and 120 or length(r) not between 5 and 500 then raise exception 'Nome ou motivo inválido';end if;
 update public.branches set name=btrim(p_name) where id=b.id;
 insert into public.audit_logs(tenant_id,company_id,actor_id,action,entity_type,entity_id,changes) values(b.tenant_id,b.company_id,auth.uid(),'branch.edited','branch',b.id,jsonb_build_object('reason',r,'before',b.name,'after',btrim(p_name)));
 return b.id;
end $$;
-- Empty units may be removed. Foreign keys are the final safeguard against concurrent references.
create or replace function private.sgi_delete_empty_branch(p_id uuid,p_reason text) returns uuid language plpgsql security definer set search_path='' as $$
declare b public.branches%rowtype; r text:=btrim(coalesce(p_reason,'')); p uuid;
begin
 select * into b from public.branches where id=p_id for update;
 if not found or auth.uid() is null or not private.is_tenant_admin(b.tenant_id) or length(r) not between 5 and 500 then raise exception 'Acesso negado ou motivo inválido';end if;
 if exists(select 1 from public.orders where branch_id=b.id) or exists(select 1 from public.delivery_bookings where branch_id=b.id) or exists(select 1 from public.customers where created_branch_id=b.id) or exists(select 1 from public.commercial_sellers where branch_id=b.id) or exists(select 1 from public.user_memberships where branch_id=b.id) then raise exception 'Unidade possui vínculos ou movimentações. Exclusão bloqueada';end if;
 for p in select pool_id from public.logistics_pool_branches where branch_id=b.id order by pool_id loop
  perform 1 from public.logistics_pools where id=p for update;
  if not exists(select 1 from public.logistics_pool_branches where pool_id=p and branch_id<>b.id) and (exists(select 1 from public.delivery_slots where pool_id=p) or exists(select 1 from public.manifests where pool_id=p)) then raise exception 'Central possui agenda ou romaneios. Exclusão bloqueada';end if;
  delete from public.logistics_pool_branches where pool_id=p and branch_id=b.id;
  if not exists(select 1 from public.logistics_pool_branches where pool_id=p) then delete from public.logistics_pools where id=p;end if;
 end loop;
 delete from public.branches where id=b.id;
 insert into public.audit_logs(tenant_id,company_id,actor_id,action,entity_type,entity_id,changes) values(b.tenant_id,b.company_id,auth.uid(),'branch.deleted_empty','branch',b.id,jsonb_build_object('reason',r,'before',to_jsonb(b)));
 return b.id;
end $$;
-- Company is logically excluded to preserve FK-backed audit records; only truly empty registrations qualify.
create or replace function private.sgi_archive_empty_company(p_id uuid,p_reason text) returns uuid language plpgsql security definer set search_path='' as $$
declare c public.companies%rowtype; r text:=btrim(coalesce(p_reason,''));
begin
 select * into c from public.companies where id=p_id for update;
 if not found or auth.uid() is null or not private.is_tenant_admin(c.tenant_id) or not c.active or length(r) not between 5 and 500 then raise exception 'Acesso negado, empresa inativa ou motivo inválido';end if;
 if exists(select 1 from public.branches where company_id=c.id) or exists(select 1 from public.orders where company_id=c.id) or exists(select 1 from public.delivery_bookings where company_id=c.id) or exists(select 1 from public.customers where company_id=c.id) or exists(select 1 from public.products where company_id=c.id) or exists(select 1 from public.commercial_sellers where company_id=c.id) or exists(select 1 from public.user_memberships where company_id=c.id) or exists(select 1 from public.order_counters where company_id=c.id) or exists(select 1 from public.sales_policies where company_id=c.id) then raise exception 'Empresa possui unidades, vínculos, configurações ou movimentações. Exclusão bloqueada';end if;
 update public.companies set active=false where id=c.id;
 insert into public.audit_logs(tenant_id,company_id,actor_id,action,entity_type,entity_id,changes) values(c.tenant_id,c.id,auth.uid(),'company.archived_empty','company',c.id,jsonb_build_object('reason',r,'before',to_jsonb(c)));
 return c.id;
end $$;
create or replace function public.sgi_edit_company(p_id uuid,p_expected jsonb,p_legal text,p_trade text,p_cnpj text,p_reason text) returns uuid language sql set search_path='' as $$select private.sgi_edit_company($1,$2,$3,$4,$5,$6)$$;
create or replace function public.sgi_edit_branch(p_id uuid,p_expected text,p_name text,p_reason text) returns uuid language sql set search_path='' as $$select private.sgi_edit_branch($1,$2,$3,$4)$$;
create or replace function public.sgi_delete_empty_branch(p_id uuid,p_reason text) returns uuid language sql set search_path='' as $$select private.sgi_delete_empty_branch($1,$2)$$;
create or replace function public.sgi_archive_empty_company(p_id uuid,p_reason text) returns uuid language sql set search_path='' as $$select private.sgi_archive_empty_company($1,$2)$$;
revoke all on function private.sgi_edit_company(uuid,jsonb,text,text,text,text),public.sgi_edit_company(uuid,jsonb,text,text,text,text),private.sgi_edit_branch(uuid,text,text,text),public.sgi_edit_branch(uuid,text,text,text),private.sgi_delete_empty_branch(uuid,text),public.sgi_delete_empty_branch(uuid,text),private.sgi_archive_empty_company(uuid,text),public.sgi_archive_empty_company(uuid,text) from public,anon,authenticated;
grant execute on function private.sgi_edit_company(uuid,jsonb,text,text,text,text),public.sgi_edit_company(uuid,jsonb,text,text,text,text),private.sgi_edit_branch(uuid,text,text,text),public.sgi_edit_branch(uuid,text,text,text),private.sgi_delete_empty_branch(uuid,text),public.sgi_delete_empty_branch(uuid,text),private.sgi_archive_empty_company(uuid,text),public.sgi_archive_empty_company(uuid,text) to authenticated;
