-- Tenant-level preference. Existing records are not rewritten.
create table if not exists private.sgi_text_preferences(tenant_id uuid primary key references public.tenants(id), enabled boolean not null default true);
alter table private.sgi_text_preferences enable row level security;
revoke all on private.sgi_text_preferences from public,anon,authenticated;
create or replace function private.sgi_text_enabled(p_tenant uuid) returns boolean language sql stable set search_path='' as $$select coalesce((select enabled from private.sgi_text_preferences where tenant_id=p_tenant),true)$$;
create or replace function private.sgi_text_enabled_company(p_company uuid) returns boolean language sql stable set search_path='' as $$select private.sgi_text_enabled((select tenant_id from public.companies where id=p_company))$$;
create or replace function private.sgi_get_text_preference(p_tenant uuid) returns boolean language plpgsql stable security definer set search_path='' as $$begin if auth.uid() is null or not private.can_see_tenant(p_tenant) then raise exception 'Acesso negado';end if;return private.sgi_text_enabled(p_tenant);end$$;
create or replace function private.sgi_set_text_preference(p_tenant uuid,p_enabled boolean) returns boolean language plpgsql security definer set search_path='' as $$declare old_value boolean;begin
 if auth.uid() is null or not private.is_tenant_admin(p_tenant) or p_enabled is null then raise exception 'Acesso negado';end if;
 perform 1 from public.tenants where id=p_tenant for update;
 old_value:=private.sgi_text_enabled(p_tenant);
 insert into private.sgi_text_preferences values(p_tenant,p_enabled) on conflict(tenant_id) do update set enabled=excluded.enabled;
 insert into public.audit_logs(tenant_id,actor_id,action,entity_type,entity_id,changes) values(p_tenant,auth.uid(),'settings.text_format_changed','tenant',p_tenant,jsonb_build_object('before',old_value,'after',p_enabled));
 return p_enabled;
end$$;
create or replace function public.sgi_get_text_preference(p_tenant uuid) returns boolean language sql set search_path='' as $$select private.sgi_get_text_preference($1)$$;
create or replace function public.sgi_set_text_preference(p_tenant uuid,p_enabled boolean) returns boolean language sql set search_path='' as $$select private.sgi_set_text_preference($1,$2)$$;
revoke all on function private.sgi_text_enabled(uuid),private.sgi_text_enabled_company(uuid),private.sgi_get_text_preference(uuid),private.sgi_set_text_preference(uuid,boolean),public.sgi_get_text_preference(uuid),public.sgi_set_text_preference(uuid,boolean) from public,anon,authenticated;
grant execute on function private.sgi_get_text_preference(uuid),private.sgi_set_text_preference(uuid,boolean),public.sgi_get_text_preference(uuid),public.sgi_set_text_preference(uuid,boolean) to authenticated;
create or replace function private.sgi_normalize_customer_row() returns trigger language plpgsql security definer set search_path='' as $$begin if private.sgi_text_enabled(new.tenant_id) then new.name:=private.sgi_title_text(new.name);end if;return new;end$$;
create or replace function private.sgi_normalize_address_row() returns trigger language plpgsql security definer set search_path='' as $$begin if private.sgi_text_enabled_company(new.company_id) then new.label:=private.sgi_title_text(new.label);new.street:=private.sgi_title_text(new.street);new.neighborhood:=private.sgi_title_text(new.neighborhood);new.city:=private.sgi_title_text(new.city);new.complement:=private.sgi_title_text(new.complement);new.reference_point:=private.sgi_title_text(new.reference_point);end if;new.state:=upper(btrim(new.state));return new;end$$;
create or replace function private.sgi_normalize_product_row() returns trigger language plpgsql security definer set search_path='' as $$begin if private.sgi_text_enabled(new.tenant_id) then new.name:=private.sgi_title_text(new.name);new.color:=private.sgi_title_text(new.color);end if;new.sku:=upper(btrim(new.sku));return new;end$$;
create or replace function private.sgi_normalize_order_item_row() returns trigger language plpgsql security definer set search_path='' as $$begin if private.sgi_text_enabled_company(new.company_id) then new.name:=private.sgi_title_text(new.name);new.color:=private.sgi_title_text(new.color);end if;new.size_text:=nullif(regexp_replace(btrim(coalesce(new.size_text,'')),'[[:space:]]+',' ','g'),'');return new;end$$;
create or replace function private.sgi_normalize_order_notes_row() returns trigger language plpgsql security definer set search_path='' as $$begin if private.sgi_text_enabled(new.tenant_id) then new.notes:=private.sgi_sentence_text(new.notes);end if;return new;end$$;
create or replace function private.sgi_normalize_manual_delivery() returns trigger language plpgsql security definer set search_path='' as $$declare k text;v text;begin
 if new.manual_order is null or not private.sgi_text_enabled(new.tenant_id) then return new;end if;
 -- Preserve seller snapshot, references, contact details, units and free-text line breaks.
 foreach k in array array['customer','city','neighborhood','street'] loop
  if new.manual_order->>k is not null then new.manual_order:=jsonb_set(new.manual_order,array[k],to_jsonb(private.sgi_title_text(new.manual_order->>k)));end if;
 end loop;
 foreach k in array array['products','notes'] loop
  if new.manual_order->>k is not null then
   select string_agg(private.sgi_sentence_text(x.line),E'\n' order by x.n) into v from unnest(string_to_array(new.manual_order->>k,E'\n')) with ordinality x(line,n);
   new.manual_order:=jsonb_set(new.manual_order,array[k],to_jsonb(coalesce(v,'')));
  end if;
 end loop;
 return new;
end$$;
drop trigger if exists sgi_normalize_manual_delivery on public.delivery_bookings;
create trigger sgi_normalize_manual_delivery before insert or update of manual_order on public.delivery_bookings for each row execute function private.sgi_normalize_manual_delivery();
revoke all on function private.sgi_normalize_manual_delivery(),private.sgi_normalize_customer_row(),private.sgi_normalize_address_row(),private.sgi_normalize_product_row(),private.sgi_normalize_order_item_row(),private.sgi_normalize_order_notes_row() from public,anon,authenticated;
-- Opening a date is distinct from reserving a blocked order.
create or replace function private.sgi_smart_open_day(p_company uuid,p_branch uuid,p_pool uuid,p_date date,p_capacity int) returns uuid language plpgsql security definer set search_path='' as $$
declare v_tenant uuid;v_region uuid;v_id uuid;v_used int;v_today date:=(now() at time zone 'America/Recife')::date;
begin
 if auth.uid() is null or not private.allowed(p_company,p_branch,'shipping.write') or p_date is null or p_date<v_today or p_date>v_today+180 or p_capacity is null or p_capacity not between 1 and 100 then raise exception 'Sem autorização ou data/capacidade inválida';end if;
 select tenant_id into v_tenant from public.companies where id=p_company and active;
 perform 1 from public.logistics_pools lp where lp.id=p_pool and lp.tenant_id=v_tenant and lp.active and exists(select 1 from public.logistics_pool_branches pb join public.branches br on br.id=pb.branch_id where pb.pool_id=lp.id and pb.branch_id=p_branch and br.company_id=p_company and br.active) for update;
 if not found then raise exception 'Central não atende esta loja';end if;
 if exists(select 1 from public.delivery_slots where pool_id=p_pool and delivery_date=p_date and smart_route) then raise exception 'Data já aberta. Atualize a consulta';end if;
 select coalesce(sum(reserved),0)::int into v_used from public.delivery_slots where pool_id=p_pool and delivery_date=p_date;
 if p_capacity<v_used then raise exception 'Capacidade inferior às reservas existentes';end if;
 insert into public.delivery_regions(tenant_id,name,smart_system) values(v_tenant,'Agenda inteligente (sistema)',true) on conflict(tenant_id,name) do nothing;
 select id into v_region from public.delivery_regions where tenant_id=v_tenant and name='Agenda inteligente (sistema)' and smart_system and active;
 if v_region is null then raise exception 'Região interna indisponível';end if;
 insert into public.delivery_slots(tenant_id,pool_id,region_id,delivery_date,capacity,smart_route) values(v_tenant,p_pool,v_region,p_date,p_capacity,true) returning id into v_id;
 insert into public.audit_logs(tenant_id,company_id,actor_id,action,entity_type,entity_id,changes) values(v_tenant,p_company,auth.uid(),'smart_day.opened','delivery_slot',v_id,jsonb_build_object('date',p_date,'capacity',p_capacity,'without_booking',true));
 return v_id;
end$$;
create or replace function public.sgi_smart_open_day(p_company uuid,p_branch uuid,p_pool uuid,p_date date,p_capacity int) returns uuid language sql set search_path='' as $$select private.sgi_smart_open_day($1,$2,$3,$4,$5)$$;
revoke all on function private.sgi_smart_open_day(uuid,uuid,uuid,date,int),public.sgi_smart_open_day(uuid,uuid,uuid,date,int) from public,anon,authenticated;
grant execute on function private.sgi_smart_open_day(uuid,uuid,uuid,date,int),public.sgi_smart_open_day(uuid,uuid,uuid,date,int) to authenticated;
-- Exact group summary: read-only and restricted to the Master of this tenant.
create or replace function private.sgi_group_overview(p_tenant uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$declare v jsonb;begin
 if auth.uid() is null or not private.is_tenant_admin(p_tenant) then raise exception 'Visão consolidada exclusiva do Master';end if;
 select coalesce(jsonb_agg(to_jsonb(q) order by q.trade_name),'[]'::jsonb) into v from (
 select c.id,c.trade_name,
 (select count(*) from public.orders o where o.company_id=c.id and o.commercial_status='confirmed' and o.deleted_at is null) orders,
 (select coalesce(sum(o.products_gross-o.products_discount),0) from public.orders o where o.company_id=c.id and o.commercial_status='confirmed' and o.deleted_at is null) net,
 (select coalesce(sum(r.amount_due),0) from public.receivables r join public.orders o on o.id=r.order_id where r.company_id=c.id and o.company_id=c.id and r.status='open' and o.commercial_status='confirmed' and o.deleted_at is null) receivable,
 (select count(*) from public.delivery_bookings b where b.company_id=c.id and b.status in ('scheduled','loaded','in_route')) deliveries
 from public.companies c where c.tenant_id=p_tenant and c.active
 ) q;return v;
end$$;
create or replace function public.sgi_group_overview(p_tenant uuid) returns jsonb language sql set search_path='' as $$select private.sgi_group_overview($1)$$;
revoke all on function private.sgi_group_overview(uuid),public.sgi_group_overview(uuid) from public,anon,authenticated;
grant execute on function private.sgi_group_overview(uuid),public.sgi_group_overview(uuid) to authenticated;
