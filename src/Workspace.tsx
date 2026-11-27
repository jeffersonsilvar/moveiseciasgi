import {useEffect,useState} from 'react';
import type {SupabaseClient,User} from '@supabase/supabase-js';
import {BarChart3,CalendarCheck,ChevronDown,ClipboardList,Factory,LayoutGrid,LogOut,Menu,Package,Plus,Settings2,ShoppingBag,Truck,Users,X,Wallet,ShieldCheck} from 'lucide-react';
import type {Membership,Company,Branch,Page,AppContext} from './lib/types';
import {GroupOverview} from './components/GroupOverview';
import {setTextFormatting,titleCaseBR} from './lib/utils';
import {Dashboard} from './pages/Dashboard';
import {Customers} from './pages/Customers';
import {Catalog} from './pages/Catalog';
import {OrderForm} from './pages/OrderForm';
import {Orders,OrderDetail} from './pages/Orders';
import {Finance} from './pages/Finance';
import {Production} from './pages/Production';
import {Logistics,Manifests} from './pages/Logistics';
import {Settings} from './pages/Settings';
import {SellerReport} from './pages/SellerReport';
import {CommercialSellers} from './pages/CommercialSellers';
const pages:Record<Page,string>={dashboard:'Visão geral',orders:'Pedidos e vendas','new-order':'Novo pedido','order-detail':'Detalhe do pedido',customers:'Clientes',catalog:'Produtos',finance:'Financeiro',production:'Fabricação',logistics:'Agenda e entregas',manifests:'Romaneios',settings:'Configurações','seller-report':'Relatório de vendedores','commercial-sellers':'Vendedores'};
const navigation: {group:string;items:{key:Page;label:string;icon:typeof LayoutGrid}[]}[]=[
 {group:'OPERAÇÃO',items:[{key:'dashboard',label:'Visão geral',icon:LayoutGrid},{key:'orders',label:'Pedidos e vendas',icon:ShoppingBag},{key:'customers',label:'Clientes',icon:Users},{key:'commercial-sellers',label:'Vendedores',icon:Users},{key:'catalog',label:'Produtos',icon:Package}]},
 {group:'GESTÃO DE OPERAÇÃO',items:[{key:'finance',label:'Financeiro',icon:Wallet},{key:'production',label:'Fabricação',icon:Factory},{key:'logistics',label:'Agenda e entregas',icon:Truck},{key:'manifests',label:'Romaneios',icon:ClipboardList}]},
 {group:'GESTÃO',items:[{key:'seller-report',label:'Relatório de vendedores',icon:BarChart3},{key:'settings',label:'Configurações',icon:Settings2}]}
];
export default function Workspace({db,user,memberships,companies,branches,onSignOut}:{db:SupabaseClient;user:User;memberships:Membership[];companies:Company[];branches:Branch[];onSignOut:()=>void}){
 const groupIds=[...new Set(memberships.filter(m=>m.active&&m.role==='tenant_admin').map(m=>m.tenant_id))];
 const [selection,setSelection]=useState(companies.length===1&&groupIds.length<=1?companies[0].id:companies.length===0&&groupIds.length===1?'group:'+groupIds[0]:'');
 const groupMode=selection.startsWith('group:')&&groupIds.includes(selection.slice(6));
 const companyId=companies.some(c=>c.id===selection)?selection:'';
 const tenantId=groupMode?selection.slice(6):companies.find(c=>c.id===companyId)?.tenant_id??'';
 const tenantMemberships=memberships.filter(m=>m.active&&m.tenant_id===tenantId);
 const scoped=tenantMemberships.filter(m=>!m.company_id||m.company_id===companyId);
 const isAdmin=tenantMemberships.some(m=>m.role==='tenant_admin');
 const allowedBranches=branches.filter(b=>b.company_id===companyId&&scoped.some(m=>!m.branch_id||m.branch_id===b.id));
 const [preferredBranch,setPreferredBranch]=useState('');
 const branchId=allowedBranches.some(b=>b.id===preferredBranch)?preferredBranch:allowedBranches[0]?.id??'';
 const operational=scoped.filter(m=>!m.branch_id||m.branch_id===branchId);
 const canManage=isAdmin||operational.some(m=>['company_admin','manager'].includes(m.role));
 const canFinance=canManage||operational.some(m=>m.role==='finance');
 const canProduction=canManage||operational.some(m=>m.role==='production');
 const canShipping=canManage||operational.some(m=>m.role==='shipping');
 const isCashier=operational.some(m=>m.role==='cashier')&&!operational.some(m=>m.role!=='cashier');
 const canWrite=canManage||operational.some(m=>['seller','cashier'].includes(m.role));
 const canCancel=operational.some(m=>['tenant_admin','company_admin'].includes(m.role));
 const [page,setPage]=useState<Page>('dashboard');const [orderId,setOrderId]=useState<string|undefined>();
 const [formatReady,setFormatReady]=useState('');const [formatError,setFormatError]=useState('');
 const [menu,setMenu]=useState(false);const [notice,setNotice]=useState<{text:string;type:'success'|'error'}|null>(null);
 const [version,setVersion]=useState(0);
 useEffect(()=>{let live=true;setFormatReady('');setFormatError('');if(!tenantId)return;void Promise.resolve(db.rpc('sgi_get_text_preference',{p_tenant:tenantId})).then(({data,error})=>{if(!live)return;if(error){setFormatError(error.message);return;}setTextFormatting(data===true);setFormatReady(tenantId)}).catch(()=>{if(live)setFormatError('Não foi possível consultar a preferência de textos.');});return()=>{live=false}},[tenantId,version]);
 const choose=(id:string)=>{if(!companies.some(c=>c.id===id)&&!(id.startsWith('group:')&&groupIds.includes(id.slice(6))))return;setSelection(id);setPreferredBranch('');setOrderId(undefined);setPage('dashboard');setNotice(null);setMenu(false);setVersion(v=>v+1);window.scrollTo(0,0)};
 const notify=(text:string,type:'success'|'error'='success')=>{setNotice({text,type});};
 const go=(next:Page,id?:string)=>{if(groupMode&&next!=='dashboard'&&next!=='settings')return;if(isCashier&&!['orders','new-order','order-detail','customers','catalog'].includes(next))return;setOrderId(id);setPage(next);setMenu(false);window.scrollTo({top:0,behavior:'instant'})};
 const context:AppContext={db,user,memberships:tenantMemberships,companies:companies.filter(c=>c.tenant_id===tenantId),branches:branches.filter(b=>companies.some(c=>c.id===b.company_id&&c.tenant_id===tenantId)),companyId,branchId,tenantId,isAdmin,isCashier,canCancel,canManage,canWrite,canFinance,canShipping,canProduction,notify,go,refresh:()=>setVersion(v=>v+1)};
 const activeCompany=companies.find(c=>c.id===companyId);
 const allowed=(key:Page)=>{
   if(groupMode)return key==='dashboard'||(key==='settings'&&isAdmin&&!companies.some(c=>c.tenant_id===tenantId));
   if(isCashier)return ['orders','new-order','order-detail','customers','catalog'].includes(key);
   if(key==='settings')return isAdmin;
   if(key==='finance')return canFinance;
   if(key==='production')return canProduction;
   if(key==='manifests'||key==='logistics')return canShipping||canWrite;
   if(key==='catalog')return true;
   if(key==='seller-report')return canManage||canWrite;
   if(key==='commercial-sellers')return canManage||canWrite;
   return true;
 };
 const currentPage=isCashier&&!['orders','new-order','order-detail','customers','catalog'].includes(page)?'orders':page;
 if(!tenantId)return <div className="sgi-auth-page"><div className="sgi-login"><h2>Selecione a empresa</h2><p>Escolha o ambiente em que deseja trabalhar.</p>{companies.map(c=><button key={c.id} className="sgi-button" style={{marginBottom:8}} onClick={()=>choose(c.id)}>{c.trade_name}</button>)}{groupIds.map(t=><button key={t} className="sgi-button" style={{marginBottom:8}} onClick={()=>choose('group:'+t)}>Todas as empresas do grupo{groupIds.length>1?' · '+(companies.find(c=>c.tenant_id===t)?.trade_name??t.slice(0,8)):''} — visão gerencial</button>)}<button className="sgi-auth-link" onClick={onSignOut}>Sair</button></div></div>;
 if(formatReady!==tenantId)return <div className="sgi-auth-page"><div className="sgi-login"><h2>{formatError?'Não foi possível carregar as configurações':'Preparando ambiente...'}</h2>{formatError&&<><p>{formatError}</p><button className="sgi-button" onClick={()=>setVersion(v=>v+1)}>Tentar novamente</button></>}<button className="sgi-auth-link" onClick={onSignOut}>Sair</button></div></div>;
 return <div className="app-layout">
  {menu&&<button className="mobile-backdrop" aria-label="Fechar menu" onClick={()=>setMenu(false)}/>}
  <aside className={'sidebar '+(menu?'show':'')}>
    <div className="brand"><div className="brand-icon"><img src="/brand-symbol.png" alt="Símbolo Móveis & Cia" /></div><div className="brand-copy"><strong>Móveis & Cia</strong><small>SGI · Commerce OS</small></div><button className="mobile-close" aria-label="Fechar navegação" onClick={()=>setMenu(false)}><X size={18}/></button></div>
    <div className="workspace-switch"><div className="workspace-symbol">MC</div><div><strong>{groupMode?'Todas as empresas':titleCaseBR(activeCompany?.trade_name??'Móveis & Cia Gold')}</strong><span>{isAdmin?'Administração do grupo':isCashier?'Caixa · Emissão de pedidos':'Operação comercial'}</span></div><ChevronDown size={15}/></div>
    <nav aria-label="Menu principal">{navigation.filter(section=>section.items.some(x=>allowed(x.key))).map(section=><div className="nav-group" key={section.group}><div className="nav-group-title">{section.group}</div>{section.items.filter(x=>allowed(x.key)).map(({key,label,icon:Icon})=><button key={key} className={'nav-item '+((page===key||(key==='orders'&&['new-order','order-detail'].includes(page)))?'active':'')} onClick={()=>go(key)}><Icon size={17} strokeWidth={1.8}/>{label}</button>)}</div>)}</nav>
    <div className="sidebar-footer"><div className="online-dot"/><span>Ambiente conectado</span><small>Supabase · acesso controlado</small><button onClick={onSignOut}><LogOut size={15}/> Encerrar sessão</button></div>
  </aside>
  <div className="app-main"><header className="topbar"><div className="crumb"><button className="burger" onClick={()=>setMenu(true)} aria-label="Abrir menu"><Menu size={20}/></button><span>SGI</span><span className="crumb-divider">/</span><strong>{pages[currentPage]}</strong></div><div className="topbar-right">
   {(companies.length>1||groupIds.length>0)&&<label className="header-company"><select aria-label="Empresa de operação" value={selection} onChange={e=>choose(e.target.value)}>{companies.map(c=><option value={c.id} key={c.id}>{titleCaseBR(c.trade_name)}</option>)}{groupIds.map(t=><option key={t} value={'group:'+t}>Todas as empresas{groupIds.length>1?' · '+(companies.find(c=>c.tenant_id===t)?.trade_name??t.slice(0,8)):''} (consulta)</option>)}</select><ChevronDown size={14}/></label>}
   {allowedBranches.length>1&&<label className="header-company"><select aria-label="Loja de operação" value={branchId} onChange={e=>{setPreferredBranch(e.target.value);go(isCashier?'orders':'dashboard');setVersion(v=>v+1)}}>{allowedBranches.map(b=><option key={b.id} value={b.id}>{b.name}</option>)}</select><ChevronDown size={14}/></label>}
   <span className="secure-mini"><ShieldCheck size={14}/> Acesso seguro</span><div className="profile-avatar">{(user.email??'U').slice(0,2).toUpperCase()}</div>
  </div></header>
  <main className="screen" key={`${currentPage}-${selection}-${version}`}>
   {notice&&<div className={'notice '+notice.type} role="status"><span>{notice.text}</span><button onClick={()=>setNotice(null)} aria-label="Fechar aviso"><X size={16}/></button></div>}
   {groupMode&&currentPage==='dashboard'?<GroupOverview db={db} tenant={tenantId} onCompany={choose}/>:!companies.length&&currentPage!=='settings'?<div className="empty-onboarding"><div className="onboarding-icon"><CalendarCheck size={28}/></div><h1>Vamos preparar sua operação</h1><p>Sua conta está ativa, mas ainda não há nenhuma empresa visível. Um Master deve cadastrar uma empresa e uma loja.</p>{isAdmin&&<button className="btn primary" onClick={()=>go('settings')}>Configurar empresa <Plus size={17}/></button>}</div>:<>
    {currentPage==='dashboard'&&<Dashboard ctx={context}/>}
    {currentPage==='customers'&&<Customers ctx={context}/>}
    {currentPage==='catalog'&&<Catalog ctx={context}/>}
    {currentPage==='orders'&&<Orders ctx={context}/>}
    {currentPage==='new-order'&&<OrderForm ctx={context} editId={orderId}/>}
    {currentPage==='order-detail'&&orderId&&<OrderDetail ctx={context} id={orderId}/>}
    {currentPage==='finance'&&<Finance ctx={context}/>}
    {currentPage==='production'&&<Production ctx={context}/>}
    {currentPage==='logistics'&&<Logistics ctx={context}/>}
    {currentPage==='manifests'&&<Manifests ctx={context}/>}
    {currentPage==='settings'&&isAdmin&&<Settings ctx={context}/>}
    {currentPage==='seller-report'&&<SellerReport ctx={context}/>}
    {currentPage==='commercial-sellers'&&<CommercialSellers ctx={context}/>}
   </>}
  </main></div>
 </div>;
}
