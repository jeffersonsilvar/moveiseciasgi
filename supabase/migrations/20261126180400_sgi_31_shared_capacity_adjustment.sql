-- Change a shared daily capacity only under administrative authority over the entire central.
create or replace function private.sgi_smart_set_capacity(p_pool uuid,p_date date,p_expected int,p_capacity int)
returns void language plpgsql security definer set search_path='' as $$
declare lp public.logistics_pools%rowtype;s public.delivery_slots%rowtype;v_used int;
begin
 if auth.uid() is null or p_capacity is null or p_capacity not between 1 and 100 or p_date is null or p_date<(now() at time zone 'America/Recife')::date then raise exception 'Capacidade ou data inválida';end if;
 select * into lp from public.logistics_pools where id=p_pool and active for update;
 if not found or not exists(select 1 from public.logistics_pool_branches where pool_id=p_pool) or
 exists(select 1 from public.logistics_pool_branches pb join public.branches br on br.id=pb.branch_id where pb.pool_id=p_pool and not private.allowed(br.company_id,br.id,'admin.read'))
 then raise exception 'Somente gestor autorizado em todas as lojas da central pode ajustar a capacidade';end if;
 select * into s from public.delivery_slots where pool_id=p_pool and delivery_date=p_date and smart_route and active for update;
 if not found or s.capacity is distinct from p_expected then raise exception 'Data ou capacidade alterada. Atualize a agenda';end if;
 select coalesce(sum(reserved),0)::int into v_used from public.delivery_slots where pool_id=p_pool and delivery_date=p_date;
 if p_capacity<v_used then raise exception 'Capacidade inferior às reservas existentes';end if;
 update public.delivery_slots set capacity=p_capacity where id=s.id;
 insert into public.audit_logs(tenant_id,actor_id,action,entity_type,entity_id,changes) values(lp.tenant_id,auth.uid(),'smart_day.capacity_changed','delivery_slot',s.id,jsonb_build_object('old_capacity',s.capacity,'new_capacity',p_capacity,'date',p_date));
end $$;
create or replace function public.sgi_smart_set_capacity(p_pool uuid,p_date date,p_expected int,p_capacity int) returns void language sql set search_path='' as $$select private.sgi_smart_set_capacity($1,$2,$3,$4)$$;
revoke all on function public.sgi_smart_set_capacity(uuid,date,int,int),private.sgi_smart_set_capacity(uuid,date,int,int) from public,anon,authenticated;
grant execute on function public.sgi_smart_set_capacity(uuid,date,int,int),private.sgi_smart_set_capacity(uuid,date,int,int) to authenticated;
