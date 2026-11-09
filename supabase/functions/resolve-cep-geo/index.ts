// Approximate CEP-centroid geocoding for suggestions only. Never use for proof of delivery.
// Secrets supplied by Supabase Edge Functions runtime. No service credentials in the frontend.
import { createClient } from 'npm:@supabase/supabase-js@2.57.0';
const originHeaders = {'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type','Access-Control-Allow-Methods':'POST, OPTIONS','Content-Type':'application/json'};
const reply=(payload:unknown,status=200)=>new Response(JSON.stringify(payload),{status,headers:originHeaders});
Deno.serve(async(req:Request)=>{
 if(req.method==='OPTIONS') return new Response(null,{status:204,headers:originHeaders});
 if(req.method!=='POST')return reply({error:'Método inválido'},405);
 const url=Deno.env.get('SUPABASE_URL');
 const anon=Deno.env.get('SUPABASE_ANON_KEY');
 const secret=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
 if(!url||!anon||!secret)return reply({error:'Serviço indisponível'},503);
 const bearer=req.headers.get('authorization')??'';
 if(!bearer.startsWith('Bearer '))return reply({error:'Autenticação obrigatória'},401);
 try{
   const input=await req.json() as {tenant_id?:string;cep?:string};
   const tenant=String(input.tenant_id??'');const cep=String(input.cep??'').replace(/\D/g,'');
   if(!/^[0-9a-f-]{36}$/i.test(tenant)||!/^[0-9]{8}$/.test(cep))return reply({error:'Tenant ou CEP inválido'},400);
   const token=bearer.slice(7);
   const userClient=createClient(url,anon,{global:{headers:{Authorization:bearer}},auth:{persistSession:false,autoRefreshToken:false}});
   const {data:auth,error:authError}=await userClient.auth.getUser(token);
   if(authError||!auth.user)return reply({error:'Sessão inválida'},401);
   const admin=createClient(url,secret,{auth:{persistSession:false,autoRefreshToken:false}});
   const [{data:membership,error:memberError},{data:profile}]=await Promise.all([
     admin.from('user_memberships').select('id').eq('tenant_id',tenant).eq('user_id',auth.user.id).eq('active',true).limit(1),
     admin.from('profiles').select('active').eq('id',auth.user.id).maybeSingle()
   ]);
   if(memberError||!membership?.length||!profile?.active)return reply({error:'Sem vínculo ativo com a empresa'},403);
   const {data:existing}=await admin.from('sgi_postcode_geocodes').select('lat,lon,source,fetched_at').eq('tenant_id',tenant).eq('cep',cep).maybeSingle();
   if(existing&&new Date(existing.fetched_at).getTime()>Date.now()-30*86400_000)
     return reply({available:true,approximate:true,lat:existing.lat,lon:existing.lon,source:existing.source,cached:true});
   const {count}=await admin.from('sgi_postcode_geocodes').select('*',{count:'exact',head:true}).eq('tenant_id',tenant).gte('fetched_at',new Date(Date.now()-3600_000).toISOString());
   if((count??0)>150)return reply({available:false,message:'Limite de atualização de coordenadas atingido. Continue pelo agrupamento por região.'},429);
   const api=await fetch(`https://brasilapi.com.br/api/cep/v2/${cep}`,{headers:{Accept:'application/json'},signal:AbortSignal.timeout(6500)});
   if(!api.ok)return reply({available:false,message:'Coordenadas indisponíveis para este CEP. Consulte as regiões cadastradas.'});
   const geo=await api.json() as {location?:{coordinates?:{latitude?:string|number;longitude?:string|number}}};
   const lat=Number(geo.location?.coordinates?.latitude);const lon=Number(geo.location?.coordinates?.longitude);
   if(!Number.isFinite(lat)||!Number.isFinite(lon)||lat<-34||lat>6||lon<-74||lon>-33||(!lat&&!lon))
     return reply({available:false,message:'Este CEP não possui coordenadas válidas. A região manual permanece disponível.'});
   const {error:writeError}=await admin.from('sgi_postcode_geocodes').upsert({tenant_id:tenant,cep,lat,lon,source:'brasilapi_cep_v2',precision:'cep_approx',fetched_at:new Date().toISOString()},{onConflict:'tenant_id,cep'});
   if(writeError)return reply({available:false,message:'Falha ao armazenar localização aproximada.'},503);
   return reply({available:true,approximate:true,lat,lon,source:'brasilapi_cep_v2',cached:false});
 }catch{
   return reply({available:false,message:'Não foi possível consultar a geolocalização. Utilize a agenda regional.'});
 }
});
