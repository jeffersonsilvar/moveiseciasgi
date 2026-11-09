-- SGI Commerce OS v1.0-rc. Security, monthly sales, geocoding-based advisory route suggestions.
-- Non-destructive migration; no user/customer data is removed.

ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS confirmed_at timestamptz;
COMMENT ON COLUMN public.orders.confirmed_at IS 'Time the order was confirmed. NULL on legacy confirmed orders: use created_at only as approximate legacy fallback.';

CREATE OR REPLACE FUNCTION private.sgi_capture_confirmation()
RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF NEW.commercial_status='confirmed' AND NEW.confirmed_at IS NULL
 AND (TG_OP='INSERT' OR OLD.commercial_status IS DISTINCT FROM 'confirmed') THEN
   NEW.confirmed_at:=now();
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.sgi_capture_confirmation() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS sgi_capture_confirmation ON public.orders;
CREATE TRIGGER sgi_capture_confirmation BEFORE INSERT OR UPDATE OF commercial_status
ON public.orders FOR EACH ROW EXECUTE FUNCTION private.sgi_capture_confirmation();
CREATE INDEX IF NOT EXISTS sgi_orders_confirmed_month_idx ON public.orders(company_id,confirmed_at,seller_user_id)
WHERE commercial_status='confirmed' AND deleted_at IS NULL;

CREATE OR REPLACE FUNCTION private.sgi_seller_monthly_report(p_company uuid,p_month date)
RETURNS TABLE(seller_id uuid,seller_name text,order_count bigint,products_gross numeric,
 products_discount numeric,products_net numeric,legacy_date_count bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF auth.uid() IS NULL OR p_month IS NULL OR NOT EXISTS(
   SELECT 1 FROM public.branches b WHERE b.company_id=p_company
     AND private.allowed(b.company_id,b.id,'orders.read')) THEN
   RAISE EXCEPTION 'Sem acesso ao relatório desta empresa';
 END IF;
 RETURN QUERY
 SELECT o.seller_user_id,coalesce(nullif(pr.display_name,''),'Vendedor') AS seller_name,
        count(*)::bigint,coalesce(sum(o.products_gross),0)::numeric,
        coalesce(sum(o.products_discount),0)::numeric,
        coalesce(sum(o.products_gross-o.products_discount),0)::numeric,
        count(*) FILTER (WHERE o.confirmed_at IS NULL)::bigint
 FROM public.orders o
 LEFT JOIN public.profiles pr ON pr.id=o.seller_user_id
 WHERE o.company_id=p_company AND o.commercial_status='confirmed' AND o.deleted_at IS NULL
 AND coalesce(o.confirmed_at,o.created_at) >= date_trunc('month',p_month::timestamp)
 AND coalesce(o.confirmed_at,o.created_at) < date_trunc('month',p_month::timestamp)+interval '1 month'
 AND private.allowed(o.company_id,o.branch_id,'orders.read')
 AND (o.seller_user_id=auth.uid() OR private.allowed(o.company_id,o.branch_id,'admin.read'))
 GROUP BY o.seller_user_id,pr.display_name
 ORDER BY coalesce(sum(o.products_gross-o.products_discount),0) DESC;
END $$;
REVOKE ALL ON FUNCTION private.sgi_seller_monthly_report(uuid,date) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.sgi_seller_monthly_report(uuid,date) TO authenticated;
CREATE OR REPLACE FUNCTION public.sgi_seller_monthly_report(p_company uuid,p_month date)
RETURNS TABLE(seller_id uuid,seller_name text,order_count bigint,products_gross numeric,
 products_discount numeric,products_net numeric,legacy_date_count bigint)
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT * FROM private.sgi_seller_monthly_report(p_company,p_month);
$$;
REVOKE ALL ON FUNCTION public.sgi_seller_monthly_report(uuid,date) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.sgi_seller_monthly_report(uuid,date) TO authenticated;

CREATE OR REPLACE FUNCTION private.sgi_admin_list_users(p_tenant uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v jsonb;
BEGIN
 IF auth.uid() IS NULL OR NOT private.is_tenant_admin(p_tenant) THEN
   RAISE EXCEPTION 'Acesso restrito ao administrador do grupo';
 END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.display_name,x.email), '[]'::jsonb) INTO v
 FROM (
   SELECT m.id AS membership_id,m.user_id,u.email,coalesce(nullif(p.display_name,''),split_part(u.email,'@',1)) AS display_name,
    m.tenant_id,m.company_id,m.branch_id,m.role,m.active,
    (SELECT count(*) FROM public.audit_logs al WHERE al.actor_id=m.user_id AND al.tenant_id=m.tenant_id)
    +(SELECT count(*) FROM public.orders o WHERE o.created_by=m.user_id AND o.tenant_id=m.tenant_id)
    +(SELECT count(*) FROM public.order_payments pay JOIN public.orders o ON o.id=pay.order_id
      WHERE pay.registered_by=m.user_id AND o.tenant_id=m.tenant_id)
      AS movement_count
   FROM public.user_memberships m
   JOIN auth.users u ON u.id=m.user_id
   JOIN public.profiles p ON p.id=m.user_id
   WHERE m.tenant_id=p_tenant
 ) x;
 RETURN v;
END $$;
REVOKE ALL ON FUNCTION private.sgi_admin_list_users(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.sgi_admin_list_users(uuid) TO authenticated;
CREATE OR REPLACE FUNCTION public.sgi_admin_list_users(p_tenant uuid)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT private.sgi_admin_list_users(p_tenant);
$$;
REVOKE ALL ON FUNCTION public.sgi_admin_list_users(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.sgi_admin_list_users(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION private.sgi_admin_manage_membership(
 p_membership uuid,p_action text,p_new_role text DEFAULT NULL,p_display_name text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE m public.user_memberships%rowtype;v_old text;
BEGIN
 SELECT * INTO m FROM public.user_memberships WHERE id=p_membership FOR UPDATE;
 IF NOT FOUND OR auth.uid() IS NULL OR NOT private.is_tenant_admin(m.tenant_id)
 THEN RAISE EXCEPTION 'Vínculo inexistente ou acesso negado'; END IF;
 IF p_action NOT IN ('activate','deactivate','rename','change_role','remove_unlinked') THEN
   RAISE EXCEPTION 'Ação não autorizada'; END IF;
 IF m.user_id=auth.uid() AND p_action IN ('deactivate','change_role','remove_unlinked') THEN
   RAISE EXCEPTION 'Não é permitido desativar ou rebaixar seu próprio acesso'; END IF;
 IF m.role='tenant_admin' AND p_action IN ('deactivate','change_role','remove_unlinked') AND
    (SELECT count(*) FROM public.user_memberships WHERE tenant_id=m.tenant_id AND role='tenant_admin' AND active)=1
 THEN RAISE EXCEPTION 'O último Master ativo não pode ser removido'; END IF;
 v_old:=m.role;
 CASE p_action
 WHEN 'activate' THEN UPDATE public.user_memberships SET active=true WHERE id=m.id;
 WHEN 'deactivate' THEN UPDATE public.user_memberships SET active=false WHERE id=m.id;
 WHEN 'rename' THEN
  IF length(trim(coalesce(p_display_name,''))) NOT BETWEEN 2 AND 120 THEN RAISE EXCEPTION 'Nome inválido'; END IF;
  UPDATE public.profiles SET display_name=trim(p_display_name),updated_at=now() WHERE id=m.user_id;
 WHEN 'change_role' THEN
  IF p_new_role IS NULL OR p_new_role NOT IN ('tenant_admin','company_admin','manager','seller','shipping','finance','production','viewer')
     OR (m.company_id IS NULL AND p_new_role<>'tenant_admin')
     OR (m.company_id IS NOT NULL AND p_new_role='tenant_admin') THEN
     RAISE EXCEPTION 'Alteração de escopo administrativo exige novo vínculo autorizado'; END IF;
  UPDATE public.user_memberships SET role=p_new_role WHERE id=m.id;
 WHEN 'remove_unlinked' THEN
  IF m.active THEN RAISE EXCEPTION 'Desative o vínculo antes da remoção'; END IF;
  IF EXISTS(SELECT 1 FROM public.orders WHERE tenant_id=m.tenant_id AND (seller_user_id=m.user_id OR created_by=m.user_id))
    OR EXISTS(SELECT 1 FROM public.audit_logs WHERE tenant_id=m.tenant_id AND actor_id=m.user_id)
    OR EXISTS(SELECT 1 FROM public.customers c WHERE c.tenant_id=m.tenant_id AND c.created_by=m.user_id)
    OR EXISTS(SELECT 1 FROM public.delivery_bookings b WHERE b.tenant_id=m.tenant_id AND b.booked_by=m.user_id)
    OR EXISTS(SELECT 1 FROM public.manifests f WHERE f.tenant_id=m.tenant_id AND f.created_by=m.user_id)
  THEN RAISE EXCEPTION 'Usuário tem histórico; mantenha o vínculo inativo'; END IF;
  DELETE FROM public.user_memberships WHERE id=m.id;
 END CASE;
 INSERT INTO public.audit_logs(tenant_id,company_id,actor_id,action,entity_type,entity_id,changes)
 VALUES(m.tenant_id,m.company_id,auth.uid(),'membership.'||p_action,'user_membership',m.id,
 jsonb_build_object('user_id',m.user_id,'old_role',v_old,'new_role',p_new_role));
END $$;
REVOKE ALL ON FUNCTION private.sgi_admin_manage_membership(uuid,text,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.sgi_admin_manage_membership(uuid,text,text,text) TO authenticated;
CREATE OR REPLACE FUNCTION public.sgi_admin_manage_membership(
 p_membership uuid,p_action text,p_new_role text DEFAULT NULL,p_display_name text DEFAULT NULL)
RETURNS void LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT private.sgi_admin_manage_membership(p_membership,p_action,p_new_role,p_display_name);
$$;
REVOKE ALL ON FUNCTION public.sgi_admin_manage_membership(uuid,text,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.sgi_admin_manage_membership(uuid,text,text,text) TO authenticated;

-- Coordinates are recorded by an authenticated server-side geocoder only; never trust client-supplied coordinates.
CREATE TABLE IF NOT EXISTS public.sgi_postcode_geocodes (
 tenant_id uuid NOT NULL REFERENCES public.tenants(id),cep text NOT NULL CHECK(cep~'^[0-9]{8}$'),
 lat double precision NOT NULL CHECK(lat BETWEEN -34 AND 6),
 lon double precision NOT NULL CHECK(lon BETWEEN -74 AND -33),
 source text NOT NULL,precision text NOT NULL DEFAULT 'cep_approx',
 fetched_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(tenant_id,cep)
);
ALTER TABLE public.sgi_postcode_geocodes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sgi_postcode_geocodes FROM anon,authenticated;

CREATE OR REPLACE FUNCTION private.sgi_haversine_km(lat1 double precision,lon1 double precision,lat2 double precision,lon2 double precision)
RETURNS double precision LANGUAGE sql IMMUTABLE STRICT SET search_path='' AS $$
 SELECT 6371.0*2.0*asin(sqrt(least(1.0,greatest(0.0,
  power(sin(radians(lat2-lat1)/2),2) + cos(radians(lat1))*cos(radians(lat2))*power(sin(radians(lon2-lon1)/2),2)
 ))));
$$;
REVOKE ALL ON FUNCTION private.sgi_haversine_km(double precision,double precision,double precision,double precision) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.sgi_haversine_km(double precision,double precision,double precision,double precision) TO authenticated;

-- Advisory distance: match only regions with approved neighborhood mapping. No new delivery capacity is invented.
-- Existing scheduled stops on the same date/pool provide an approximate distance reference using CEP centroids.
CREATE OR REPLACE FUNCTION private.sgi_suggest_distance_slots(p_order uuid)
RETURNS TABLE(slot_id uuid,deliver_on date,region_name text,available integer,capacity integer,
  approx_km numeric,signal text,observation text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE o public.orders%rowtype;
BEGIN
 SELECT * INTO o FROM public.orders WHERE id=p_order;
 IF NOT FOUND OR auth.uid() IS NULL OR NOT private.allowed(o.company_id,o.branch_id,'orders.read')
 THEN RAISE EXCEPTION 'Acesso negado ao pedido'; END IF;
 RETURN QUERY
 WITH destination AS (
  SELECT g.lat,g.lon FROM public.sgi_postcode_geocodes g WHERE g.tenant_id=o.tenant_id
   AND g.cep=regexp_replace(coalesce(o.delivery_address_snapshot->>'cep',''),'[^0-9]','','g')
 ),
 matched AS (
  SELECT s.id,s.delivery_date,r.name,s.capacity,s.reserved,s.pool_id
  FROM public.delivery_slots s
  JOIN public.delivery_regions r ON r.id=s.region_id AND r.active
  JOIN public.delivery_region_areas a ON a.region_id=r.id
  JOIN public.logistics_pool_branches pb ON pb.pool_id=s.pool_id AND pb.branch_id=o.branch_id
  WHERE s.tenant_id=o.tenant_id AND s.active AND s.delivery_date BETWEEN current_date AND current_date+45
   AND s.reserved<s.capacity
   AND private.sgi_location_key(a.city)=private.sgi_location_key(o.delivery_address_snapshot->>'city')
   AND private.sgi_location_key(a.neighborhood)=private.sgi_location_key(o.delivery_address_snapshot->>'neighborhood')
 )
 SELECT m.id,m.delivery_date,m.name,(m.capacity-m.reserved)::integer,m.capacity,
  round(d.nearest_km::numeric,1) AS approx_km,
  CASE WHEN d.nearest_km IS NULL THEN 'regional'
       WHEN d.nearest_km<=4 THEN 'nearby'
       WHEN d.nearest_km<=10 THEN 'moderate' ELSE 'far' END,
  CASE WHEN d.nearest_km IS NULL THEN 'Região atendida; sem coordenadas suficientes para estimar a proximidade.'
       ELSE 'Distância em linha reta aproximada entre CEPs; não é quilometragem rodoviária.' END
 FROM matched m
 LEFT JOIN LATERAL (
  SELECT min(private.sgi_haversine_km(ref.lat,ref.lon,ge.lat,ge.lon)) AS nearest_km
  FROM destination ref
  JOIN public.delivery_bookings b ON b.slot_id IN (
    SELECT sx.id FROM public.delivery_slots sx WHERE sx.pool_id=m.pool_id AND sx.delivery_date=m.delivery_date)
    AND b.status IN ('scheduled','loaded','in_route')
  JOIN public.orders prior_order ON prior_order.id=b.order_id AND prior_order.tenant_id=o.tenant_id
  JOIN public.sgi_postcode_geocodes ge ON ge.tenant_id=o.tenant_id
    AND ge.cep=regexp_replace(coalesce(prior_order.delivery_address_snapshot->>'cep',''),'[^0-9]','','g')
 ) d ON true
 ORDER BY CASE WHEN d.nearest_km IS NULL THEN 1 ELSE 0 END,
          m.delivery_date ASC,d.nearest_km ASC
 LIMIT 12;
END $$;
REVOKE ALL ON FUNCTION private.sgi_suggest_distance_slots(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.sgi_suggest_distance_slots(uuid) TO authenticated;
CREATE OR REPLACE FUNCTION public.sgi_suggest_distance_slots(p_order uuid)
RETURNS TABLE(slot_id uuid,deliver_on date,region_name text,available integer,capacity integer,
  approx_km numeric,signal text,observation text)
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT * FROM private.sgi_suggest_distance_slots(p_order);
$$;
REVOKE ALL ON FUNCTION public.sgi_suggest_distance_slots(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.sgi_suggest_distance_slots(uuid) TO authenticated;
