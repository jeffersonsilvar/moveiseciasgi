-- SGI v0.9.6: flexible zones, observed locations, reversible manufacturing release.
-- Operations are atomic; only authenticated tenant admins or production personnel may invoke them.

-- Keep cancellation history, but allow a new valid booking for the same order.
alter table public.delivery_bookings drop constraint if exists delivery_bookings_order_id_key;
create unique index if not exists delivery_bookings_one_active_per_order
  on public.delivery_bookings(order_id) where status <> 'cancelled';

create or replace function private.sgi_manage_region(
 p_tenant uuid, p_region uuid, p_action text, p_name text default null, p_locations jsonb default '[]'::jsonb
) returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_region uuid:=p_region; v_area jsonb; v_city text; v_neighborhood text;
 v_existed boolean; v_added integer:=0; v_removed integer:=0; v_owner uuid;
begin
 if not private.is_tenant_admin(p_tenant) then raise exception 'Somente o administrador do grupo pode editar regiões'; end if;
 if p_action not in ('create','rename','add_areas','remove_areas','archive','restore') then raise exception 'Ação inválida'; end if;
 if jsonb_typeof(coalesce(p_locations,'[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_locations,'[]'::jsonb))>80 then
   raise exception 'Informe até 80 bairros por operação';
 end if;
 -- Serializes concurrent changes to the geography dictionary of this tenant.
 perform pg_advisory_xact_lock(hashtext(p_tenant::text));
 if p_action='create' then
   if char_length(trim(coalesce(p_name,'')))<3 then raise exception 'Nome de região inválido'; end if;
   insert into public.delivery_regions(tenant_id,name) values(p_tenant,trim(p_name)) returning id into v_region;
 else
   select tenant_id into v_owner from public.delivery_regions where id=p_region for update;
   if v_owner is null or v_owner<>p_tenant then raise exception 'Região inexistente ou de outro grupo'; end if;
 end if;
 if p_action='rename' then
   if char_length(trim(coalesce(p_name,'')))<3 then raise exception 'Nome inválido'; end if;
   update public.delivery_regions set name=trim(p_name) where id=v_region;
 elsif p_action='archive' then
   if exists(select 1 from public.delivery_slots s where s.region_id=v_region and s.reserved>0 and s.delivery_date>=current_date) then
     raise exception 'Região possui entregas futuras reservadas. Reagende antes de desativar.';
   end if;
   update public.delivery_regions set active=false where id=v_region;
   update public.delivery_slots set active=false where region_id=v_region and delivery_date>=current_date and reserved=0;
 elsif p_action='restore' then
   update public.delivery_regions set active=true where id=v_region;
 end if;
 if p_action in ('create','add_areas','remove_areas') then
   if p_action<>'remove_areas' and not exists(select 1 from public.delivery_regions where id=v_region and active) then
     raise exception 'Reative esta região para editar bairros';
   end if;
   for v_area in select value from jsonb_array_elements(coalesce(p_locations,'[]'::jsonb)) loop
     v_city:=trim(coalesce(v_area->>'city',''));v_neighborhood:=trim(coalesce(v_area->>'neighborhood',''));
     if char_length(v_city)<2 or char_length(v_neighborhood)<2 or char_length(v_city)>100 or char_length(v_neighborhood)>100 then
       raise exception 'Cidade e bairro devem ter de 2 a 100 caracteres';
     end if;
     if p_action in ('create','add_areas') then
       if exists (
        select 1 from public.delivery_region_areas a
        join public.delivery_regions r on r.id=a.region_id
        where r.tenant_id=p_tenant and r.active and r.id<>v_region
         and private.sgi_location_key(a.city)=private.sgi_location_key(v_city)
         and private.sgi_location_key(a.neighborhood)=private.sgi_location_key(v_neighborhood)
       ) then raise exception 'Bairro % / % já pertence a outra região ativa',v_neighborhood,v_city;end if;
       select exists(select 1 from public.delivery_region_areas a where a.region_id=v_region
        and private.sgi_location_key(a.city)=private.sgi_location_key(v_city)
        and private.sgi_location_key(a.neighborhood)=private.sgi_location_key(v_neighborhood)) into v_existed;
       if not v_existed then
         insert into public.delivery_region_areas(region_id,city,neighborhood)
         values(v_region,lower(v_city),lower(v_neighborhood));v_added:=v_added+1;
       end if;
     else
       if exists (
         select 1 from public.delivery_bookings b
         join public.delivery_slots s on s.id=b.slot_id
         join public.orders o on o.id=b.order_id
         where s.region_id=v_region and b.status in ('scheduled','loaded','in_route')
           and private.sgi_location_key(o.delivery_address_snapshot->>'city')=private.sgi_location_key(v_city)
           and private.sgi_location_key(o.delivery_address_snapshot->>'neighborhood')=private.sgi_location_key(v_neighborhood)
       ) then raise exception 'Bairro possui entregas ativas. Reagende antes de removê-lo.';end if;
       delete from public.delivery_region_areas a where a.region_id=v_region
         and private.sgi_location_key(a.city)=private.sgi_location_key(v_city)
         and private.sgi_location_key(a.neighborhood)=private.sgi_location_key(v_neighborhood);
       get diagnostics v_removed = row_count;
     end if;
   end loop;
 end if;
 insert into public.audit_logs(tenant_id,actor_id,action,entity_type,entity_id,changes)
 values(p_tenant,auth.uid(),'region.'||p_action,'delivery_region',v_region,
 jsonb_build_object('name',p_name,'areas',p_locations,'added',v_added));
 return jsonb_build_object('region_id',v_region,'action',p_action,'added',v_added);
end $fn$;
revoke all on function private.sgi_manage_region(uuid,uuid,text,text,jsonb) from public,anon;
grant execute on function private.sgi_manage_region(uuid,uuid,text,text,jsonb) to authenticated;
create or replace function public.sgi_manage_region(
 p_tenant uuid,p_region uuid,p_action text,p_name text default null,p_locations jsonb default '[]'::jsonb
) returns jsonb language sql security invoker set search_path=''
as $$ select private.sgi_manage_region(p_tenant,p_region,p_action,p_name,p_locations) $$;
revoke all on function public.sgi_manage_region(uuid,uuid,text,text,jsonb) from public,anon;
grant execute on function public.sgi_manage_region(uuid,uuid,text,text,jsonb) to authenticated;

create or replace function private.sgi_discover_neighborhoods(p_tenant uuid)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_result jsonb;
begin
 if not private.is_tenant_admin(p_tenant) then raise exception 'Acesso negado';end if;
 select coalesce(jsonb_agg(to_jsonb(q) order by q.orders desc,q.city,q.neighborhood),'[]'::jsonb)
 into v_result from (
  select min(o.delivery_address_snapshot->>'city') as city,
   min(o.delivery_address_snapshot->>'neighborhood') as neighborhood,
   count(*)::int as orders
  from public.orders o
  where o.tenant_id=p_tenant and o.commercial_status='confirmed' and o.deleted_at is null
   and coalesce(trim(o.delivery_address_snapshot->>'city'),'')<>''
   and coalesce(trim(o.delivery_address_snapshot->>'neighborhood'),'')<>''
   and not exists (
    select 1 from public.delivery_regions r join public.delivery_region_areas a on a.region_id=r.id
    where r.tenant_id=p_tenant and r.active
     and private.sgi_location_key(a.city)=private.sgi_location_key(o.delivery_address_snapshot->>'city')
     and private.sgi_location_key(a.neighborhood)=private.sgi_location_key(o.delivery_address_snapshot->>'neighborhood')
   )
  group by private.sgi_location_key(o.delivery_address_snapshot->>'city'),
   private.sgi_location_key(o.delivery_address_snapshot->>'neighborhood')
  order by count(*) desc limit 60
 ) q;
 return v_result;
end $fn$;
revoke all on function private.sgi_discover_neighborhoods(uuid) from public,anon;
grant execute on function private.sgi_discover_neighborhoods(uuid) to authenticated;
create or replace function public.sgi_discover_neighborhoods(p_tenant uuid)
returns jsonb language sql security invoker set search_path=''
as $$ select private.sgi_discover_neighborhoods(p_tenant) $$;
revoke all on function public.sgi_discover_neighborhoods(uuid) from public,anon;
grant execute on function public.sgi_discover_neighborhoods(uuid) to authenticated;

create or replace function private.sgi_change_item_availability(
 p_item uuid,p_status text,p_reason text,p_eta date default null
) returns jsonb language plpgsql security definer set search_path='' as $fn$
declare o public.orders%rowtype;i public.order_items%rowtype;b public.delivery_bookings%rowtype;
 v_cancelled boolean:=false;
begin
 if p_status not in ('ready','manufacturing','ordered','blocked') then raise exception 'Situação inválida';end if;
 if char_length(trim(coalesce(p_reason,'')))<8 then raise exception 'Informe uma justificativa de pelo menos 8 caracteres';end if;
 select i0.order_id into o.id from public.order_items i0 where i0.id=p_item;
 select * into o from public.orders where id=o.id for update;
 if not found or o.commercial_status<>'confirmed' or o.deleted_at is not null or
  not private.allowed(o.company_id,o.branch_id,'production.write') then raise exception 'Sem permissão para alterar a fabricação';end if;
 select * into i from public.order_items where id=p_item and order_id=o.id for update;
 if not found then raise exception 'Item não encontrado';end if;
 if i.availability_status=p_status and i.production_eta is not distinct from p_eta then
   return jsonb_build_object('status',p_status,'changed',false,'booking_cancelled',false);
 end if;
 select * into b from public.delivery_bookings where order_id=o.id and status<>'cancelled' for update;
 if b.id is not null and b.status in ('loaded','in_route','delivered','failed') then
   raise exception 'Pedido já foi para carga ou rota. Regularize na expedição antes de modificar a fabricação.';
 end if;
 if p_status<>'ready' and b.id is not null and b.status='scheduled' then
  update public.delivery_slots set reserved=reserved-1 where id=b.slot_id and reserved>0;
  if not found then raise exception 'Inconsistência na capacidade de entrega. Operação abortada.';end if;
  update public.delivery_bookings set status='cancelled',delivery_notes='Reserva cancelada por reversão da fabricação: '||left(trim(p_reason),300)
   where id=b.id;
  v_cancelled:=true;
  insert into public.audit_logs(tenant_id,company_id,actor_id,action,entity_type,entity_id,changes)
  values(o.tenant_id,o.company_id,auth.uid(),'delivery.auto_cancel_for_production','delivery_booking',b.id,
  jsonb_build_object('item',i.id,'reason',left(trim(p_reason),300)));
 end if;
 update public.order_items set availability_status=p_status,
  production_eta=case when p_status='ready' then null else p_eta end,
  production_ready_at=case when p_status='ready' then now() else null end,
  production_ready_by=case when p_status='ready' then auth.uid() else null end
 where id=i.id;
 update public.orders set availability_status=
  case when exists(select 1 from public.order_items it where it.order_id=o.id and it.availability_status='manufacturing') then 'manufacturing'
       when exists(select 1 from public.order_items it where it.order_id=o.id and it.availability_status='ordered') then 'ordered'
       when exists(select 1 from public.order_items it where it.order_id=o.id and it.availability_status='blocked') then 'blocked'
       else 'ready' end,updated_at=now() where id=o.id;
 insert into public.audit_logs(tenant_id,company_id,actor_id,action,entity_type,entity_id,changes)
 values(o.tenant_id,o.company_id,auth.uid(),'production.availability_changed','order_item',i.id,
 jsonb_build_object('from',i.availability_status,'to',p_status,'reason',trim(p_reason),'eta',p_eta,'booking_cancelled',v_cancelled));
 return jsonb_build_object('status',p_status,'changed',true,'booking_cancelled',v_cancelled);
end $fn$;
revoke all on function private.sgi_change_item_availability(uuid,text,text,date) from public,anon;
grant execute on function private.sgi_change_item_availability(uuid,text,text,date) to authenticated;
create or replace function public.sgi_change_item_availability(
 p_item uuid,p_status text,p_reason text,p_eta date default null
) returns jsonb language sql security invoker set search_path=''
as $$ select private.sgi_change_item_availability(p_item,p_status,p_reason,p_eta) $$;
revoke all on function public.sgi_change_item_availability(uuid,text,text,date) from public,anon;
grant execute on function public.sgi_change_item_availability(uuid,text,text,date) to authenticated;

-- Once a booking is cancelled, a confirmed order can be rebooked in the future.
do $guard$
declare v text;needle text;
begin
 select pg_get_functiondef('private.sgi_book_delivery(uuid,uuid)'::regprocedure) into v;
 needle:='where b.order_id=p_order)';
 if position(needle in v)=0 then raise exception 'Assinatura do agendamento alterada; rever manualmente';end if;
 execute replace(v,needle,'where b.order_id=p_order and b.status<>''cancelled'')');
end $guard$;
