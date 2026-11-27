import {useEffect,useState} from 'react';
import {RefreshCw,ShieldCheck,UserRoundCheck,UserRoundX} from 'lucide-react';
import type {AppContext} from '../lib/types';
import {Panel,Field} from './UI';
import {userAdmin,strongPassword,passwordHint} from '../lib/userAdmin';
type Person={membership_id:string;user_id:string;email:string;display_name:string;company_id:string|null;branch_id:string|null;role:string;active:boolean;movement_count:number};
const roleNames:Record<string,string>={tenant_admin:'Master',company_admin:'Admin da empresa',manager:'Gerente',seller:'Vendedor',cashier:'Caixa — Emissão de pedidos',shipping:'Expedição',finance:'Financeiro',production:'Fabricação',viewer:'Consulta'};
export function UserManager({ctx}:{ctx:AppContext}){
 const [users,setUsers]=useState<Person[]>([]);const [busy,setBusy]=useState(false);const [version,setVersion]=useState(0);const [err,setErr]=useState('');
 useEffect(()=>{let live=true;void ctx.db.rpc('sgi_admin_list_users',{p_tenant:ctx.tenantId}).then(({data,error})=>{
  if(!live)return;if(error){setErr(error.message);return;}setUsers((data??[]) as Person[]);setErr('');
 });return()=>{live=false};},[ctx.tenantId,version]);
 const [resetTarget,setResetTarget]=useState<Person|null>(null);const [newPassword,setNewPassword]=useState('');const [again,setAgain]=useState('');
 const closeReset=()=>{setResetTarget(null);setNewPassword('');setAgain('');};
 const reset=async(e:React.FormEvent)=>{
  e.preventDefault();if(busy||!resetTarget||!ctx.isAdmin||!strongPassword(newPassword)||newPassword!==again)return;
  setBusy(true);setErr('');
  try{
   const result=await userAdmin(ctx.db,{action:'reset',tenant:ctx.tenantId,user_id:resetTarget.user_id,password:newPassword});
   if(result.ok){ctx.notify(result.message);closeReset();}
   else setErr(result.message);
  }finally{setBusy(false);setNewPassword('');setAgain('');}
 };
 const action=async(user:Person,type:'rename'|'activate'|'deactivate'|'change_role'|'remove_unlinked')=>{
  let name:string|null=null;let role:string|null=null;
  if(type==='rename'){name=prompt('Nome de exibição do usuário:',user.display_name);if(!name||name.trim().length<2)return;}
  if(type==='change_role'){
   role=prompt('Novo perfil (cashier, seller, manager, finance, shipping, production, viewer, company_admin):',user.role);
   if(!role||!roleNames[role])return;
  }
  if(type==='deactivate'&&!confirm(`Inativar o acesso de ${user.display_name}?`))return;
  if(type==='remove_unlinked'&&!confirm('Remover o vínculo inativo e sem histórico? A identidade de autenticação continuará no Supabase.'))return;
  setBusy(true);setErr('');
  const {error}=await ctx.db.rpc('sgi_admin_manage_membership',{p_membership:user.membership_id,p_action:type,p_new_role:role,p_display_name:name});
  setBusy(false);if(error){setErr(error.message);return;}
  ctx.notify('Permissão atualizada com auditoria.');setVersion(v=>v+1);
 };
 return <Panel title="Usuários e acessos" sub="Ative, inative, altere perfis e nomes. Remoção de vínculo somente sem movimentações; a conta de autenticação não é apagada.">
   <div className="toolbar"><span className="tiny-muted">{users.length} vínculo(s) no grupo</span><button className="btn secondary small" onClick={()=>setVersion(v=>v+1)}><RefreshCw size={14}/> Atualizar</button></div>
   {err&&<div className="subtle-warning">{err}</div>}
   {resetTarget&&<form className="form-stack" onSubmit={reset}>
    <div className="subtle-warning">Redefinir senha de {resetTarget.display_name} ({resetTarget.email}). Confirme a identidade do funcionário antes de prosseguir. A senha será substituída sem envio de e-mail.</div>
    <div className="form-grid cols2"><Field label="Nova senha"><input type="password" required minLength={12} maxLength={72} autoComplete="new-password" value={newPassword} onChange={e=>setNewPassword(e.target.value)}/></Field><Field label="Confirmar nova senha"><input type="password" required minLength={12} maxLength={72} autoComplete="new-password" value={again} onChange={e=>setAgain(e.target.value)}/></Field></div>
    <small className="tiny-muted">{passwordHint} A redefinição não garante encerramento imediato de todos os tokens já emitidos.</small>
    <div className="action-pair"><button type="submit" className="btn primary" disabled={busy||!strongPassword(newPassword)||newPassword!==again}>Confirmar redefinição</button><button type="button" className="btn secondary" disabled={busy} onClick={closeReset}>Cancelar</button></div>
   </form>}
   <div className="table-scroll"><table><thead><tr><th>Usuário</th><th>Perfil / Unidade</th><th>Atividade</th><th>Situação</th><th>Ações</th></tr></thead><tbody>
    {users.map(u=><tr key={u.membership_id}><td><strong>{u.display_name}</strong><small>{u.email}</small></td>
     <td>{roleNames[u.role]??u.role}<small>{ctx.companies.find(c=>c.id===u.company_id)?.trade_name??'Todo o grupo'} · {ctx.branches.find(b=>b.id===u.branch_id)?.name??'Todas as unidades'}</small></td>
     <td>{u.movement_count} registro(s)</td><td><span className={'status '+(u.active?'good':'warning')}>{u.active?'Ativo':'Inativo'}</span></td><td>
      <div className="action-pair"><button disabled={busy} className="btn secondary small" onClick={()=>action(u,'rename')}>Editar nome</button>
       {u.role!=='tenant_admin'&&<button className="btn secondary small" disabled={busy} onClick={()=>action(u,'change_role')}>Perfil</button>}
       {u.user_id!==ctx.user.id&&u.role!=='tenant_admin'&&<button className="btn secondary small" disabled={busy} onClick={()=>{closeReset();setErr('');setResetTarget(u);}}>Redefinir senha</button>}
       {u.active?<button disabled={busy||!!resetTarget||u.user_id===ctx.user.id} className="btn secondary small" onClick={()=>action(u,'deactivate')}><UserRoundX size={14}/> Inativar</button>:<button disabled={busy} className="btn secondary small" onClick={()=>action(u,'activate')}><UserRoundCheck size={14}/> Ativar</button>}
       {!u.active&&Number(u.movement_count)===0&&u.user_id!==ctx.user.id&&<button className="btn danger small" disabled={busy} onClick={()=>action(u,'remove_unlinked')}>Remover vínculo</button>}
      </div></td></tr>)}
   </tbody></table></div>
   <div className="subtle-info"><ShieldCheck size={16}/> Desativar o vínculo revoga o acesso às empresas autorizadas quando as políticas do SGI forem novamente consultadas. Para bloqueio imediato de uma sessão já aberta, também revogue as sessões no Supabase Auth.</div>
 </Panel>;
}
