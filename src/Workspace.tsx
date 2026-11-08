import {useState} from 'react';
import type {SupabaseClient,User} from '@supabase/supabase-js';
import {BarChart3,CalendarCheck,ChevronDown,ClipboardList,Factory,LayoutGrid,LogOut,Menu,Package,Plus,Settings2,ShoppingBag,Truck,Users,X,Wallet,ShieldCheck} from 'lucide-react';
import type {Membership,Company,Branch,Page,AppContext} from './lib/types';
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
const pages:Record<Page,string>={dashboard:'Visão geral',orders:'Pedidos e vendas','new-order':'Novo pedido','order-detail':'Detalhe do pedido',customers:'Clientes',catalog:'Produtos',finance:'Financeiro',production:'Fabricação',logistics:'Agenda e entregas',manifests:'Romaneios',settings:'Configurações','seller-report':'Relatório de vendedores'};
const navigation: {group:string;items:{key:Page;label:string;icon:typeof LayoutGrid}[]}[]=[
 {group:'OPERAÇÃO',items:[{key:'dashboard',label:'Visão geral',icon:LayoutGrid},{key:'orders',label:'Pedidos e vendas',icon:ShoppingBag},{key:'customers',label:'Clientes',icon:Users},{key:'catalog',label:'Produtos',icon:Package}]},
 {group:'GESTÃO DE OPERAÇÃO',items:[{key:'finance',label:'Financeiro',icon:Wallet},{key:'production',label:'Fabricação',icon:Factory},{key:'logistics',label:'Agenda e entregas',icon:Truck},{key:'manifests',label:'Romaneios',icon:ClipboardList}]},
 {group:'GESTÃO',items:[{key:'seller-report',label:'Relatório de vendedores',icon:BarChart3},{key:'settings',label:'Configurações',icon:Settings2}]}
];
export default function Workspace({db,user,memberships,companies,branches,onSignOut}:{db:SupabaseClient;user:User;memberships:Membership[];companies:Company[];branches:Branch[];onSignOut:()=>void}){
 const isAdmin=memberships.some(m=>m.active&&m.role==='tenant_admin');
 const canManage=isAdmin||memberships.some(m=>m.active&&['company_admin','manager'].includes(m.role));
 const canFinance=canManage||memberships.some(m=>m.active&&m.role==='finance');
 const canProduction=canManage||memberships.some(m=>m.active&&m.role==='production');
 const canShipping=canManage||memberships.some(m=>m.active&&m.role==='shipping');
 const canWrite=canManage||memberships.some(m=>m.active&&m.role==='seller');
 const [companyId,setCompanyId]=useState(companies[0]?.id??'');
 const allowedBranches=branches.filter(b=>b.company_id===companyId);
 const [preferredBranch,setPreferredBranch]=useState('');
 const branchId=allowedBranches.some(b=>b.id===preferredBranch)?preferredBranch:allowedBranches[0]?.id??'';
 const [page,setPage]=useState<Page>('dashboard');const [orderId,setOrderId]=useState<string|undefined>();
 const [menu,setMenu]=useState(false);const [notice,setNotice]=useState<{text:string;type:'success'|'error'}|null>(null);
 const [version,setVersion]=useState(0);
 const notify=(text:string,type:'success'|'error'='success')=>{setNotice({text,type});};
 const go=(next:Page,id?:string)=>{setOrderId(id);setPage(next);setMenu(false);window.scrollTo({top:0,behavior:'instant'})};
 const context:AppContext={db,user,memberships,companies,branches,companyId,branchId,tenantId:memberships[0]?.tenant_id??'',isAdmin,canManage,canWrite,canFinance,canShipping,canProduction,notify,go,refresh:()=>setVersion(v=>v+1)};
 const activeCompany=companies.find(c=>c.id===companyId);
 const allowed=(key:Page)=>{
   if(key==='settings')return isAdmin;
   if(key==='finance')return canFinance;
   if(key==='production')return canProduction;
   if(key==='manifests'||key==='logistics')return canShipping||canWrite;
   if(key==='catalog')return true;
   if(key==='seller-report')return canManage||canWrite;
   return true;
 };
 return <div className="app-layout">
  {menu&&<button className="mobile-backdrop" aria-label="Fechar menu" onClick={()=>setMenu(false)}/>}
  <aside className={'sidebar '+(menu?'show':'')}>
    <div className="brand"><div className="brand-icon"><img src="/brand-symbol.png" alt="Símbolo Móveis & Cia" /></div><div className="brand-copy"><strong>Móveis & Cia</strong><small>SGI · Commerce OS</small></div><button className="mobile-close" aria-label="Fechar navegação" onClick={()=>setMenu(false)}><X size={18}/></button></div>
    <div className="workspace-switch"><div className="workspace-symbol">MC</div><div><strong>{activeCompany?.trade_name??'Móveis & Cia Gold'}</strong><span>{isAdmin?'Administração do grupo':'Operação comercial'}</span></div><ChevronDown size={15}/></div>
    <nav aria-label="Menu principal">{navigation.map(section=><div className="nav-group" key={section.group}><div className="nav-group-title">{section.group}</div>{section.items.filter(x=>allowed(x.key)).map(({key,label,icon:Icon})=><button key={key} className={'nav-item '+((page===key||(key==='orders'&&['new-order','order-detail'].includes(page)))?'active':'')} onClick={()=>go(key)}><Icon size={17} strokeWidth={1.8}/>{label}</button>)}</div>)}</nav>
    <div className="sidebar-footer"><div className="online-dot"/><span>Ambiente conectado</span><small>Supabase · acesso controlado</small><button onClick={onSignOut}><LogOut size={15}/> Encerrar sessão</button></div>
  </aside>
  <div className="app-main"><header className="topbar"><div className="crumb"><button className="burger" onClick={()=>setMenu(true)} aria-label="Abrir menu"><Menu size={20}/></button><span>SGI</span><span className="crumb-divider">/</span><strong>{pages[page]}</strong></div><div className="topbar-right">
   {companies.length>1&&<label className="header-company"><select value={companyId} onChange={e=>{setCompanyId(e.target.value);setPreferredBranch('');setVersion(v=>v+1);go('dashboard')}}>{companies.map(c=><option value={c.id} key={c.id}>{c.trade_name}</option>)}</select><ChevronDown size={14}/></label>}
   <span className="secure-mini"><ShieldCheck size={14}/> Acesso seguro</span><div className="profile-avatar">{(user.email??'U').slice(0,2).toUpperCase()}</div>
  </div></header>
  <main className="screen" key={`${page}-${companyId}-${version}`}>
   {notice&&<div className={'notice '+notice.type} role="status"><span>{notice.text}</span><button onClick={()=>setNotice(null)} aria-label="Fechar aviso"><X size={16}/></button></div>}
   {!companies.length&&page!=='settings'?<div className="empty-onboarding"><div className="onboarding-icon"><CalendarCheck size={28}/></div><h1>Vamos preparar sua operação</h1><p>Sua conta está ativa, mas ainda não há nenhuma empresa visível. Um Master deve cadastrar uma empresa e uma loja.</p>{isAdmin&&<button className="btn primary" onClick={()=>go('settings')}>Configurar empresa <Plus size={17}/></button>}</div>:<>
    {page==='dashboard'&&<Dashboard ctx={context}/>}
    {page==='customers'&&<Customers ctx={context}/>}
    {page==='catalog'&&<Catalog ctx={context}/>}
    {page==='orders'&&<Orders ctx={context}/>}
    {page==='new-order'&&<OrderForm ctx={context} editId={orderId}/>}
    {page==='order-detail'&&orderId&&<OrderDetail ctx={context} id={orderId}/>}
    {page==='finance'&&<Finance ctx={context}/>}
    {page==='production'&&<Production ctx={context}/>}
    {page==='logistics'&&<Logistics ctx={context}/>}
    {page==='manifests'&&<Manifests ctx={context}/>}
    {page==='settings'&&<Settings ctx={context}/>}
    {page==='seller-report'&&<SellerReport ctx={context}/>}
   </>}
  </main></div>
 </div>;
}
