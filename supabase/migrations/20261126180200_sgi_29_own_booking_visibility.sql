-- Own-order booking visibility for sales operators; no access to other orders or manual deliveries.
drop policy if exists delivery_bookings_read on public.delivery_bookings;
create policy delivery_bookings_read on public.delivery_bookings for select to authenticated using (
 (order_id is not null and (private.allowed(company_id,branch_id,'orders.read.all') or
 (private.allowed(company_id,branch_id,'orders.read') and exists(select 1 from public.orders o where o.id=delivery_bookings.order_id and o.created_by=auth.uid()))))
 or (order_id is null and private.allowed(company_id,branch_id,'shipping.consult')));
