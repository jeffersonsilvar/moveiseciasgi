import {useEffect,useState} from 'react';
import {Building2,CalendarDays,ChevronRight,MapPin,Percent,Plus,ShieldCheck,Truck,UserRound,Users} from 'lucide-react';
import type {AppContext} from '../lib/types';
import {Field,PageHead,Panel} from '../components/UI';
import {RegionsManager} from '../components/RegionsManager';
import {UserManager} from '../components/UserManager';
import {userAdmin,strongPassword,passwordHint} from '../lib/userAdmin';
type Region={id:string;tenant_id:string;name:string;active:boolean};
type Pool={id:string;name:string};
type Slot={id:string;pool_id:string;region_id:string;delivery_date:string;capacity:number;reserved:number;active:boolean};
type SettingsSection='users'|'organization'|'commercial'|'zones'|'capacity'|'fleet';
const settingsSections=[
 {id:'users',title:'Usuários e acessos',summary:'Perfis e permissões',description:'Gerencie quem pode acessar o SGI e quais atividades cada usuário pode executar.',icon:Users},
 {id:'organization',title:'Empresas e lojas',summary:'Estrutura do grupo',description:'Cadastre empresas e vincule as unidades de atendimento à empresa correta.',icon:Building2},
 {id:'commercial',title:'Política comercial',summary:'Descontos e regras',description:'Defina os limites comerciais aplicados às vendas da empresa selecionada.',icon:Percent},
 {id:'zones',title:'Zonas de entrega',summary:'Regiões e bairros',description:'Organize as áreas atendidas pela expedição e vincule bairros às regiões.',icon:MapPin},
 {id:'capacity',title:'Capacidade de entrega',summary:'Datas e vagas',description:'Configure a disponibilidade de atendimento por data, região e central logística.',icon:CalendarDays},
 {id:'fleet',title:'Frota e motoristas',summary:'Recursos de transporte',description:'Cadastre os veículos e motoristas utilizados pela central de expedição.',icon:Truck},
] as const;
const profileHelp:Record<string,string>={
 cashier:'Caixa: emissão de pedidos, consulta de produtos e atendimento ao cliente. Não pode cancelar vendas confirmadas.',
 seller:'Vendedor: perfil comercial com permissões de venda.',
 manager:'Gerente: gestão operacional, sem autorização para cancelar pedidos.',
 company_admin:'Admin da empresa: gestão operacional completa na empresa autorizada, incluindo cancelamentos.',
 finance:'Financeiro: controle de recebimentos e consultas financeiras.',
 shipping:'Expedição: gestão de entregas e romaneios.',
 production:'Fabricação: controle de produção e disponibilidade.',
 viewer:'Consulta: acesso de leitura conforme o escopo autorizado.',
 tenant_admin:'Master: administração do grupo, inclusive usuários e acessos. Conceda somente a pessoas autorizadas.'
};
export function Settings({ctx}:{ctx:AppContext}){
 const [section,setSection]=useState<SettingsSection>('users');
 const [branchCompany,setBranchCompany]=useState(ctx.companyId);
 const [companyName,setCompanyName]=useState('');const [trade,setTrade]=useState('');const [cnpj,setCnpj]=useState('');const [branchName,setBranchName]=useState('');const [userEmail,setUserEmail]=useState('');const [userRole,setUserRole]=useState('cashier');const [userCompany,setUserCompany]=useState(ctx.companyId);const [userBranch,setUserBranch]=useState(ctx.branchId);
 const [userMode,setUserMode]=useState<'create'|'link'>('create');const [userName,setUserName]=useState('');const [userPassword,setUserPassword]=useState('');const [userPasswordAgain,setUserPasswordAgain]=useState('');const [userConfirmed,setUserConfirmed]=useState(false);
 const [regions,setRegions]=useState<Region[]>([]);const [pools,setPools]=useState<Pool[]>([]);const [pool,setPool]=useState('');const [region,setRegion]=useState('');const [slotDate,setSlotDate]=useState('');const [slotCapacity,setSlotCapacity]=useState('10');const [slots,setSlots]=useState<Slot[]>([]);
 const [sellerPct,setSellerPct]=useState('0');const [requireReview,setRequireReview]=useState(false);const [vehicleName,setVehicleName]=useState('');const [vehiclePlate,setVehiclePlate]=useState('');const [vehicleCap,setVehicleCap]=useState('10');const [driverName,setDriverName]=useState('');const [driverMobile,setDriverMobile]=useState('');const [busy,setBusy]=useState(false);const [version,setVersion]=useState(0);
 useEffect(()=>{let live=true;void Promise.all([ctx.db.from('delivery_regions').select('*').eq('tenant_id',ctx.tenantId).order('name'),ctx.db.from('logistics_pools').select('id,name').eq('tenant_id',ctx.tenantId),ctx.db.from('delivery_slots').select('id,pool_id,region_id,delivery_date,capacity,reserved,active').eq('tenant_id',ctx.tenantId).order('delivery_date',{ascending:true}).limit(80)]).then(([r,p,s])=>{if(!live)return;setRegions((r.data??[]) as Region[]);setPools((p.data??[]) as Pool[]);setSlots((s.data??[]) as Slot[]);if(!pool)setPool(p.data?.[0]?.id??'');if(!region)setRegion(r.data?.[0]?.id??'')});return()=>{live=false}},[ctx.tenantId,version]);
 useEffect(()=>{if(!ctx.companyId)return;void ctx.db.from('sales_policies').select('seller_max_discount_pct,require_financial_review').eq('company_id',ctx.companyId).maybeSingle().then(({data})=>{if(data){setSellerPct(String(data.seller_max_discount_pct));setRequireReview(!!data.require_financial_review)}})},[ctx.companyId,version]);
 const invoke=async(rpc:string,params:Record<string,unknown>,success:string)=>{setBusy(true);const {data,error}=await ctx.db.rpc(rpc,params);setBusy(false);if(error){ctx.notify(error.message,'error');return null;}ctx.notify(success);setVersion(v=>v+1);return data};

 const createUser=async(e:React.FormEvent)=>{
  e.preventDefault();if(busy||!ctx.isAdmin)return;
  if(!strongPassword(userPassword)||userPassword!==userPasswordAgain){ctx.notify('Confira os requisitos e a confirmação da senha.','error');return;}
  setBusy(true);
  try{
   const result=await userAdmin(ctx.db,{action:'create',tenant:ctx.tenantId,email:userEmail.trim().toLowerCase(),name:userName.trim(),password:userPassword,role:userRole,company:userCompany||ctx.companyId,branch:userBranch||null,confirmed:userConfirmed});
   ctx.notify(result.message,result.ok?'success':'error');
   if(result.ok){setUserEmail('');setUserName('');setUserConfirmed(false);}
   setVersion(v=>v+1);
  }finally{setBusy(false);setUserPassword('');setUserPasswordAgain('');}
 };
 const selectedSection=settingsSections.find(item=>item.id===section)??settingsSections[0];
 return <><PageHead eyebrow="PLATAFORMA / ADMINISTRAÇÃO" title="Configurações" desc="Organize a administração do SGI por área, sem misturar as rotinas da operação."><span className="tag-security"><ShieldCheck size={16}/> Acesso restrito ao Master</span></PageHead>
 <div className="settings-workspace">
  <aside className="settings-navigation" aria-label="Seções de configuração">
   <div className="settings-nav-heading">ADMINISTRAÇÃO <small>Selecione uma área</small></div>
   <nav>{settingsSections.map(({id,title,summary,icon:Icon})=><button type="button" key={id} aria-current={section===id?'page':undefined} className={'settings-nav-item '+(section===id?'active':'')} onClick={()=>setSection(id)}><span className="settings-nav-icon"><Icon size={19}/></span><span className="settings-nav-label"><strong>{title}</strong><small>{summary}</small></span><ChevronRight className="settings-nav-chevron" size={15}/></button>)}</nav>
   <div className="settings-nav-foot"><ShieldCheck size={15}/><span>Alterações administrativas sujeitas às permissões e auditoria do SGI.</span></div>
  </aside>
  <section className="settings-content" aria-labelledby="settings-section-title">
   <div className="settings-section-head"><div className="settings-section-icon"><selectedSection.icon size={23}/></div><div><span className="eyebrow">CONFIGURAÇÕES / {selectedSection.summary.toUpperCase()}</span><h2 id="settings-section-title">{selectedSection.title}</h2><p>{selectedSection.description}</p></div></div>
   <div hidden={section!=='users'} className="settings-section-body settings-users-section">
    <Panel title="Cadastro e acesso de usuário" sub="Crie a conta e atribua seu perfil sem sair do Commerce OS.">
     <div className="settings-instructions"><ShieldCheck size={18}/><div><strong>Acesso exclusivo ao Master</strong><p>Crie uma conta com senha inicial individual, ou vincule uma conta existente. Não é necessário enviar convite por e-mail.</p></div></div>
     <div className="toolbar"><button type="button" className={'btn '+(userMode==='create'?'primary':'secondary')} disabled={busy} onClick={()=>{setUserMode('create');if(userRole==='tenant_admin')setUserRole('cashier');}}>Novo usuário</button><button type="button" className={'btn '+(userMode==='link'?'primary':'secondary')} disabled={busy} onClick={()=>{setUserMode('link');setUserPassword('');setUserPasswordAgain('');setUserConfirmed(false);}}>Vincular conta existente</button></div>
     <form className="form-grid cols2 settings-user-form" onSubmit={e=>{if(userMode==='create')void createUser(e);else{e.preventDefault();if(!busy)void invoke('sgi_assign_user',{p_tenant:ctx.tenantId,p_email:userEmail.trim(),p_company:userRole==='tenant_admin'?null:userCompany||ctx.companyId,p_branch:userRole==='tenant_admin'?null:userBranch||null,p_role:userRole},'Papel atribuído com auditoria.');}}}>
      {userMode==='create'&&<Field label="Nome completo"><input required minLength={2} maxLength={120} value={userName} onChange={e=>setUserName(e.target.value)} autoComplete="off"/></Field>}
      <Field label="E-mail do usuário"><input type="email" required maxLength={254} value={userEmail} onChange={e=>{setUserEmail(e.target.value);setUserConfirmed(false)}} placeholder="usuario@empresa.com" autoComplete="off"/></Field>
      <Field label="Perfil"><select value={userRole} onChange={e=>setUserRole(e.target.value)}><option value="cashier">Caixa — Emissão de pedidos</option><option value="seller">Vendedor</option><option value="manager">Gerente</option><option value="company_admin">Admin da empresa</option><option value="finance">Financeiro</option><option value="shipping">Expedição</option><option value="production">Fabricação</option><option value="viewer">Somente consulta</option>{userMode==='link'&&<option value="tenant_admin">Master do grupo</option>}</select></Field>
      <Field label="Empresa"><select required disabled={userRole==='tenant_admin'} value={userCompany||ctx.companyId} onChange={e=>{setUserCompany(e.target.value);setUserBranch('')}}>{ctx.companies.filter(c=>c.tenant_id===ctx.tenantId&&c.active).map(c=><option key={c.id} value={c.id}>{c.trade_name}</option>)}</select></Field>
      <Field label="Loja (opcional)"><select disabled={userRole==='tenant_admin'} value={userBranch} onChange={e=>setUserBranch(e.target.value)}><option value="">Todas as lojas da empresa</option>{ctx.branches.filter(b=>b.company_id===(userCompany||ctx.companyId)&&b.active).map(b=><option key={b.id} value={b.id}>{b.name}</option>)}</select></Field>
      {userMode==='create'&&<><Field label="Senha inicial"><input type="password" required minLength={12} maxLength={72} autoComplete="new-password" value={userPassword} onChange={e=>setUserPassword(e.target.value)}/></Field><Field label="Confirmar senha"><input type="password" required minLength={12} maxLength={72} autoComplete="new-password" value={userPasswordAgain} onChange={e=>setUserPasswordAgain(e.target.value)}/></Field><div className="settings-form-wide tiny-muted">{passwordHint} Entregue a senha diretamente ao funcionário por canal privado.</div><label className="checkbox-bar settings-form-wide"><input type="checkbox" required checked={userConfirmed} onChange={e=>setUserConfirmed(e.target.checked)}/> Verifiquei que o endereço de e-mail pertence ao funcionário.</label></>}
      <div className="settings-form-wide settings-profile-note">{profileHelp[userRole]}</div>
      <div className="settings-form-wide settings-form-action"><button type="submit" className="btn primary" disabled={busy||!userEmail.includes('@')||(userMode==='create'&&(!userConfirmed||userName.trim().length<2||!strongPassword(userPassword)||userPassword!==userPasswordAgain||!(userCompany||ctx.companyId)))}><Users size={16}/> {busy?'Processando...':userMode==='create'?'Criar usuário e conceder acesso':'Atribuir permissão'}</button></div>
     </form>
    </Panel>
    <UserManager ctx={ctx} key={`users-${version}`}/>
   </div>
   <div hidden={section!=='organization'} className="settings-section-body">
    <div className="settings-pair"><Panel title="Empresas do grupo" sub="Uma empresa jurídica pode possuir várias lojas."><div className="form-stack"><Field label="Razão social"><input value={companyName} onChange={e=>setCompanyName(e.target.value)} placeholder="Nome jurídico completo"/></Field><Field label="Nome fantasia"><input value={trade} onChange={e=>setTrade(e.target.value)} placeholder="Nome exibido no sistema"/></Field><Field label="CNPJ (somente dígitos)"><input value={cnpj} onChange={e=>setCnpj(e.target.value)} placeholder="Opcional" maxLength={14}/></Field><button className="btn primary" disabled={busy||!companyName||!trade} onClick={async()=>{const d=await invoke('sgi_create_company',{p_tenant:ctx.tenantId,p_legal:companyName,p_trade:trade,p_cnpj:cnpj||null},'Empresa criada com sucesso.');if(d)window.location.reload()}}><Building2 size={17}/> Criar empresa</button></div><div className="item-list">{ctx.companies.map(c=><div key={c.id}><strong>{c.trade_name}</strong><small>{c.legal_name} · {c.cnpj??'CNPJ não informado'}</small></div>)}</div></Panel>
    <Panel title="Lojas e unidades" sub="Vincule cada unidade à empresa correta."><div className="form-stack"><Field label="Empresa"><select value={branchCompany||ctx.companyId} onChange={e=>{setBranchCompany(e.target.value)}}>{ctx.companies.map(c=><option key={c.id} value={c.id}>{c.trade_name}</option>)}</select></Field><Field label="Nome da unidade"><input value={branchName} onChange={e=>setBranchName(e.target.value)} placeholder="Ex.: Loja Boa Vista"/></Field><button className="btn secondary" disabled={busy||!branchName} onClick={async()=>{const d=await invoke('sgi_create_branch',{p_company:branchCompany||ctx.companyId,p_name:branchName},'Loja cadastrada.');if(d)window.location.reload()}}><Plus size={16}/> Adicionar unidade</button></div><div className="item-list">{ctx.branches.map(b=><div key={b.id}><strong>{b.name}</strong><small>{ctx.companies.find(c=>c.id===b.company_id)?.trade_name}</small></div>)}</div></Panel></div>
   </div>
   <div hidden={section!=='commercial'} className="settings-section-body settings-policy-section">
    <Panel title="Política comercial" sub="Limite máximo de desconto para vendedores. Exceções dependem de autorização gerencial."><div className="form-stack"><Field label="Limite percentual do vendedor (%)"><input type="number" min="0" max="100" step="0.5" value={sellerPct} onChange={e=>setSellerPct(e.target.value)}/></Field><label className="checkbox-bar"><input type="checkbox" checked={requireReview} onChange={e=>setRequireReview(e.target.checked)}/> Revisão financeira (configuração preparatória)</label><button className="btn secondary" disabled={busy} onClick={()=>invoke('sgi_set_sales_policy',{p_company:ctx.companyId,p_pct:Number(sellerPct),p_review:requireReview},'Limite comercial salvo e auditado.')}><ShieldCheck size={16}/> Salvar política</button><p className="tiny-muted">Para campanhas específicas (ex.: 20% somente em sofás/poltronas), mantenha o limite geral conservador até configurar a tabela de campanhas por categoria.</p></div></Panel>
   </div>
   <div hidden={section!=='zones'} className="settings-section-body">
    {section==='zones'&&<RegionsManager ctx={ctx} onChange={()=>setVersion(v=>v+1)}/>}
   </div>
   <div hidden={section!=='capacity'} className="settings-section-body">
    <Panel title="Capacidade diária de entrega" sub="Cada rota possui um limite; reservas são bloqueadas transacionalmente."><div className="form-stack"><Field label="Central logística"><select value={pool} onChange={e=>setPool(e.target.value)}>{pools.map(p=><option key={p.id} value={p.id}>{p.name}</option>)}</select></Field><Field label="Região"><select value={region} onChange={e=>setRegion(e.target.value)}><option value="">Selecionar</option>{regions.map(r=><option key={r.id} value={r.id}>{r.name}</option>)}</select></Field><Field label="Data"><input type="date" value={slotDate} onChange={e=>setSlotDate(e.target.value)}/></Field><Field label="Limite por dia"><input type="number" min="1" max="100" value={slotCapacity} onChange={e=>setSlotCapacity(e.target.value)}/></Field><button className="btn secondary" disabled={busy||!pool||!region||!slotDate} onClick={()=>invoke('sgi_save_delivery_slot',{p_pool:pool,p_region:region,p_date:slotDate,p_capacity:Number(slotCapacity)},'Capacidade cadastrada para a data.')}><CalendarDays size={16}/> Salvar capacidade</button></div><div className="item-list">{slots.map(s=><div key={s.id}><strong>{s.delivery_date} · {regions.find(r=>r.id===s.region_id)?.name??'Região'}</strong><small>{s.reserved}/{s.capacity} vagas ocupadas</small></div>)}</div></Panel>
   </div>
   <div hidden={section!=='fleet'} className="settings-section-body">
    <div className="settings-pair"><Panel title="Cadastro de veículo" sub="Identificação e capacidade de atendimento por viagem."><div className="form-stack"><Field label="Identificação"><input value={vehicleName} onChange={e=>setVehicleName(e.target.value)} placeholder="Caminhão 01"/></Field><Field label="Placa"><input value={vehiclePlate} onChange={e=>setVehiclePlate(e.target.value)}/></Field><Field label="Capacidade de paradas"><input type="number" min="1" max="100" value={vehicleCap} onChange={e=>setVehicleCap(e.target.value)}/></Field><button className="btn secondary" disabled={busy||!vehicleName.trim()} onClick={()=>invoke('sgi_save_vehicle',{p_tenant:ctx.tenantId,p_name:vehicleName,p_plate:vehiclePlate,p_capacity:Number(vehicleCap)},'Veículo cadastrado.')}><Truck size={16}/> Cadastrar veículo</button></div></Panel>
    <Panel title="Cadastro de motorista" sub="Identificação e contato do profissional."><div className="form-stack"><Field label="Nome"><input value={driverName} onChange={e=>setDriverName(e.target.value)}/></Field><Field label="Celular"><input value={driverMobile} onChange={e=>setDriverMobile(e.target.value)}/></Field><button className="btn secondary" disabled={busy||!driverName.trim()} onClick={()=>invoke('sgi_save_driver',{p_tenant:ctx.tenantId,p_name:driverName,p_mobile:driverMobile},'Motorista cadastrado.')}><UserRound size={16}/> Cadastrar motorista</button></div></Panel></div>
   </div>
  </section>
 </div></>;
}
