
create or replace function private.sgi_location_key(p_input text)
returns text language sql immutable set search_path=''
as $body$
 select trim(regexp_replace(
   translate(lower(coalesce(p_input,'')),
     'áàâãäéèêëíìîïóòôõöúùûüç',
     'aaaaaeeeeiiiiooooouuuuc'),
   '[[:space:]]+',' ','g'))
$body$;
revoke all on function private.sgi_location_key(text) from public,anon;
grant execute on function private.sgi_location_key(text) to authenticated;

do $guard$
declare f record; definition text;old_city text;old_area text;changed text;
begin
 old_city := 'a.city=lower(trim(o.delivery_address_snapshot->>''city''))';
 old_area := 'a.neighborhood=lower(trim(o.delivery_address_snapshot->>''neighborhood''))';
 for f in select p.oid,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='private' and p.proname in ('sgi_suggest_delivery_dates','sgi_book_delivery','sgi_dispatch_queue')
 loop
  definition:=pg_get_functiondef(f.oid);
  if strpos(definition,old_city)=0 or strpos(definition,old_area)=0 then
    raise exception 'Padrão não encontrado na função %. Alteração abortada.',f.proname;
  end if;
  changed:=replace(definition,old_city,'private.sgi_location_key(a.city)=private.sgi_location_key(o.delivery_address_snapshot->>''city'')');
  changed:=replace(changed,old_area,'private.sgi_location_key(a.neighborhood)=private.sgi_location_key(o.delivery_address_snapshot->>''neighborhood'')');
  execute changed;
 end loop;
end $guard$;
