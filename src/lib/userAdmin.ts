import type {SupabaseClient} from '@supabase/supabase-js';

export const passwordHint='Mínimo de 12 caracteres, com maiúscula, minúscula, número e símbolo; máximo de 72 bytes.';
export const strongPassword=(v:string)=>v.length>=12&&new TextEncoder().encode(v).length<=72&&/[a-z]/.test(v)&&/[A-Z]/.test(v)&&/[0-9]/.test(v)&&/[^A-Za-z0-9\s]/.test(v);

type AdminRequest={action:'create';tenant:string;email:string;name:string;password:string;role:string;company:string;branch:string|null;confirmed:boolean}|{action:'reset';tenant:string;user_id:string;password:string};
export async function userAdmin(db:SupabaseClient,body:AdminRequest):Promise<{ok:boolean;message:string}>{
 try{
  const {data,error}=await db.functions.invoke('sgi-user-admin',{body});
  if(error){
   const context=(error as {context?:Response}).context;
   if(context&&typeof context.json==='function'){
    try{const payload=await context.json();if(typeof payload?.message==='string')return {ok:false,message:payload.message};}catch{}
   }
   return {ok:false,message:'Não foi possível confirmar a operação. Atualize a lista antes de tentar novamente.'};
  }
  if(data?.ok===true&&typeof data.message==='string')return {ok:true,message:data.message};
  return {ok:false,message:'Resposta não confirmada. Atualize a lista antes de tentar novamente.'};
 }catch{return {ok:false,message:'Falha de conexão. Atualize a lista antes de tentar novamente.'};}
}
