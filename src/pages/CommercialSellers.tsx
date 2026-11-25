import {useCallback,useEffect,useState} from 'react';
import {Plus,Save,Users} from 'lucide-react';
import type {AppContext} from '../lib/types';
import {Field,PageHead,Panel,ErrorBox} from '../components/UI';
import {titleCaseBR} from '../lib/utils';

type Seller={id:string;display_name:string;branch_id:string|null;active:boolean};
export function CommercialSellers({ctx}:{ctx:AppContext}){
 const [rows,setRows]=useState<Seller[]>([]);
 const [name,setName]=useState('');const [branch,setBranch]=useState('');
 const [editing,setEditing]=useState<string|null>(null);const [active,setActive]=useState(true);
 const [busy,setBusy]=useState(false);const [error,setError]=useState('');
 const load=useCallback(async()=>{
   const {data,error:err}=await ctx.db.rpc('sgi_commercial_sellers',{p_company:ctx.companyId,p_branch:null,p_include_inactive:true});
   if(err){setError(err.message);return;}
   setRows((data??[]) as Seller[]);
 },[ctx.db,ctx.companyId]);
 useEffect(()=>{void load()},[load]);
 const save=async()=>{
  if(!ctx.canManage){setError('Somente gestores podem gerenciar vendedores.');return;}
  if(name.trim().length<2){setError('Informe nome completo do vendedor.');return;}
  setBusy(true);setError('');
  const {error:err}=await ctx.db.rpc('sgi_save_commercial_seller',{
   p_company:ctx.companyId,p_branch:branch||null,p_name:titleCaseBR(name),p_id:editing,p_active:active
  });
  setBusy(false);
  if(err){setError(err.message);return;}
  setName('');setBranch('');setEditing(null);setActive(true);
  ctx.notify('Cadastro de vendedor salvo.');void load();
 };
 const select=(s:Seller)=>{setEditing(s.id);setName(s.display_name);setBranch(s.branch_id??'');setActive(s.active)};
 const branches=ctx.branches.filter(b=>b.company_id===ctx.companyId);
 return <><PageHead eyebrow="COMERCIAL / CADASTROS" title="Vendedores"
 desc="Equipe comercial independente das contas de login. O caixa seleciona o vendedor no pedido."/>
 {error&&<ErrorBox text={error}/>}
 <div className="settings-grid">
  <Panel title={editing?'Editar vendedor':'Novo vendedor'} sub="Somente gerentes e administradores podem alterar o cadastro.">
   <div className="form-stack">
    <Field label="Nome do vendedor"><input value={name} maxLength={120} onChange={e=>setName(e.target.value)} placeholder="Nome completo"/></Field>
    <Field label="Loja vinculada"><select value={branch} onChange={e=>setBranch(e.target.value)}><option value="">Todas as lojas</option>{branches.map(b=><option key={b.id} value={b.id}>{b.name}</option>)}</select></Field>
    <label className="checkbox-bar"><input type="checkbox" checked={active} onChange={e=>setActive(e.target.checked)}/> Vendedor ativo</label>
    <button className="btn primary" disabled={busy||!ctx.canManage||name.trim().length<2} onClick={()=>void save()}>{editing?<Save size={16}/>:<Plus size={16}/>} {editing?'Salvar alterações':'Cadastrar vendedor'}</button>
    {editing&&<button className="btn secondary" onClick={()=>{setEditing(null);setName('');setBranch('');setActive(true)}}>Cancelar edição</button>}
   </div>
  </Panel>
  <Panel title="Equipe comercial" sub="Vendedores inativos são preservados no histórico, mas não aparecem em novas vendas.">
   <div className="item-list">{rows.map(s=><div key={s.id}><strong><Users size={14}/> {s.display_name}</strong><small>{s.branch_id?branches.find(b=>b.id===s.branch_id)?.name??'Outra loja':'Todas as lojas'} · {s.active?'Ativo':'Inativo'}</small>{ctx.canManage&&<button type="button" className="btn secondary small" onClick={()=>select(s)}>Editar</button>}</div>)}</div>
   {!rows.length&&<p className="tiny-muted">Nenhum vendedor cadastrado. Cadastre os responsáveis pelas vendas para iniciar os testes.</p>}
  </Panel>
 </div></>;
}
