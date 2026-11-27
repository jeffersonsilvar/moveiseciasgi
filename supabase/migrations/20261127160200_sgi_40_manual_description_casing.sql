CREATE OR REPLACE FUNCTION private.sgi_normalize_manual_delivery()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$declare k text;v text;begin
 if new.manual_order is null or not private.sgi_text_enabled(new.tenant_id) then return new;end if;
 -- Preserve seller snapshot, references, contact details, units and free-text line breaks.
 foreach k in array array['customer','city','neighborhood','street'] loop
  if new.manual_order->>k is not null then new.manual_order:=jsonb_set(new.manual_order,array[k],to_jsonb(private.sgi_title_text(new.manual_order->>k)));end if;
 end loop;
 foreach k in array array['products','notes'] loop
  if new.manual_order->>k is not null then
   select string_agg(case when k='products' then regexp_replace(regexp_replace(regexp_replace(private.sgi_title_text(x.line),'([0-9][[:space:]]*)Cm\\M','\\1cm','g'),'([0-9][[:space:]]*)Mm\\M','\\1mm','g'),'([0-9][[:space:]]*)M\\M','\\1m','g') else private.sgi_sentence_text(x.line) end,E'\n' order by x.n) into v from unnest(string_to_array(new.manual_order->>k,E'\n')) with ordinality x(line,n);
   new.manual_order:=jsonb_set(new.manual_order,array[k],to_jsonb(coalesce(v,'')));
  end if;
 end loop;
 return new;
end$function$
;
