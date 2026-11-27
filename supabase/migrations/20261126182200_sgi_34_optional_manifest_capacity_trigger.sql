create or replace function private.sgi_enforce_manifest_capacity()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_manifest public.manifests%rowtype; v_limit integer; v_count integer;
begin
 select * into v_manifest from public.manifests where id=new.manifest_id for update;
 if not found or v_manifest.status<>'draft' then raise exception 'Romaneio não permite alteração de carga';end if;
 if not coalesce((v_manifest.logistics_policy->>'enforce_vehicle_stops')::boolean,false) then return new;end if;
 select capacity_stops into v_limit from public.vehicles where id=v_manifest.vehicle_id and tenant_id=v_manifest.tenant_id and active;
 if v_limit is null then raise exception 'Veículo não está ativo';end if;
 select count(*) into v_count from public.manifest_stops where manifest_id=new.manifest_id;
 if v_count>=v_limit then raise exception 'Limite de paradas do veículo atingido';end if;
 return new;
end $$;
revoke all on function private.sgi_enforce_manifest_capacity() from public,anon,authenticated;