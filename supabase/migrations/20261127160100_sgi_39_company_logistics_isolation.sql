-- New units get a company-specific logistics pool, retaining existing shared pools within a company.
create or replace function private.sgi_create_branch(p_company uuid,p_name text) returns uuid language plpgsql security definer set search_path='' as $$
declare v_tenant uuid;v_id uuid;v_pool uuid;v_name text;
begin
 select tenant_id,trade_name into v_tenant,v_name from public.companies where id=p_company and active for update;
 if v_tenant is null or auth.uid() is null or not (private.is_tenant_admin(v_tenant) or private.allowed(p_company,null,'admin.grant')) then raise exception 'Acesso negado';end if;
 if length(trim(coalesce(p_name,'')))<2 then raise exception 'Nome da loja inválido';end if;
 select lp.id into v_pool from public.logistics_pools lp where lp.tenant_id=v_tenant and lp.active
 and exists(select 1 from public.logistics_pool_branches pb join public.branches br on br.id=pb.branch_id where pb.pool_id=lp.id and br.company_id=p_company)
 and not exists(select 1 from public.logistics_pool_branches pb join public.branches br on br.id=pb.branch_id where pb.pool_id=lp.id and br.company_id<>p_company)
 order by lp.id limit 1;
 if v_pool is null then insert into public.logistics_pools(tenant_id,name) values(v_tenant,'Central · '||v_name) returning id into v_pool;end if;
 insert into public.branches(tenant_id,company_id,name) values(v_tenant,p_company,trim(p_name)) returning id into v_id;
 insert into public.logistics_pool_branches(pool_id,branch_id) values(v_pool,v_id);
 insert into public.audit_logs(tenant_id,company_id,actor_id,action,entity_type,entity_id,changes) values(v_tenant,p_company,auth.uid(),'branch.create','branch',v_id,jsonb_build_object('pool_id',v_pool));
 return v_id;
end$$;
create or replace function private.sgi_can_read_pool(p_pool uuid) returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and exists(select 1 from public.logistics_pools lp where lp.id=p_pool and (private.is_tenant_admin(lp.tenant_id) or exists(select 1 from public.logistics_pool_branches pb join public.branches b on b.id=pb.branch_id where pb.pool_id=lp.id and (private.allowed(b.company_id,b.id,'orders.read') or private.allowed(b.company_id,b.id,'shipping.consult')))))
$$;
revoke all on function private.sgi_can_read_pool(uuid) from public,anon,authenticated;
grant execute on function private.sgi_can_read_pool(uuid) to authenticated;
drop policy if exists logistics_pools_select on public.logistics_pools;
create policy logistics_pools_select on public.logistics_pools for select to authenticated using(private.sgi_can_read_pool(id));
drop policy if exists logistics_pool_branches_select on public.logistics_pool_branches;
create policy logistics_pool_branches_select on public.logistics_pool_branches for select to authenticated using(private.sgi_can_read_pool(pool_id) and exists(select 1 from public.branches b where b.id=branch_id and (private.is_tenant_admin(b.tenant_id) or private.allowed(b.company_id,b.id,'orders.read') or private.allowed(b.company_id,b.id,'shipping.consult'))));
