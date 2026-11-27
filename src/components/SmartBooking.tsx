import './smart-agenda.css';
import {useEffect,useState} from 'react';
import {CalendarCheck,CalendarPlus,MapPin,Route,RefreshCw} from 'lucide-react';
import type {AppContext} from '../lib/types';
import {dateBR,digits,today,titleCaseBR} from '../lib/utils';
import {Field,Panel,ErrorBox} from './UI';

export type ManualDelivery={reference:string;customer:string;seller:string;seller_id?:string;products:string;city:string;neighborhood:string;cep:string;street:string;number:string;phone:string;notes:string;released:boolean};
export type SmartTarget={company:string;branch:string;order?:string|null;manual?:ManualDelivery;booking?:string;originalDate?:string;pool?:string;city:string;neighborhood:string;cep?:string};
type Suggestion={id:string;pool_id:string;pool_name:string;delivery_date:string;capacity:number;used:number;signal:string;nearest_km:number|null;same_neighborhood:number;same_city:number;geo_count:number};
const signalNames:Record<string,string>={same_neighborhood:'Mesmo bairro',nearby:'CEP próximo',moderate:'Proximidade moderada',same_region:'Mesma região cadastrada',same_city:'Mesma cidade (sem distância validada)',empty:'Rota sem entregas',far:'Destino distante',unknown:'Proximidade não determinada'};
export const scopedLogistics=(ctx:AppContext,company:string,branch:string)=>ctx.memberships.some(m=>m.active&&m.tenant_id===ctx.tenantId&&(!m.company_id||m.company_id===company)&&(!m.branch_id||m.branch_id===branch)&&['tenant_admin','company_admin','manager','shipping'].includes(m.role));
const addDays=(date:string,n:number)=>{const d=new Date(date+'T12:00:00Z');d.setUTCDate(d.getUTCDate()+n);return d.toISOString().slice(0,10)};
export {addDays};

export function SmartBooking({ctx,target,onSaved,onClose,previewOnly=false,closeLabel='Fechar'}:{ctx:AppContext;target:SmartTarget;onSaved:(date:string)=>void;onClose?:()=>void;previewOnly?:boolean;closeLabel?:string}){
 const canOpen=scopedLogistics(ctx,target.company,target.branch);
 const [pools,setPools]=useState<{id:string;name:string}[]>([]);
 const [options,setOptions]=useState<Suggestion[]>([]);
 const [chosen,setChosen]=useState<Suggestion|null>(null);
 const [openNew,setOpenNew]=useState(false);
 const [pool,setPool]=useState(target.pool??'');
 const [date,setDate]=useState(today());
 const [capacity,setCapacity]=useState('');
 const [reason,setReason]=useState('');
 const [confirmed,setConfirmed]=useState(false);
 const [busy,setBusy]=useState(false);
 const [loading,setLoading]=useState(true);
 const [error,setError]=useState('');
 const [geo,setGeo]=useState('');
 const [refresh,setRefresh]=useState(0);
 useEffect(()=>{
  let live=true;
  setLoading(true);setError('');setChosen(null);setConfirmed(false);
  const run=async()=>{
   try{
    const cep=digits(target.cep??'');
    if(cep.length===8){
     try{const {data}=await ctx.db.functions.invoke('resolve-cep-geo',{body:{tenant_id:ctx.tenantId,cep}});if(live)setGeo(data?.available?'CEP localizado aproximadamente. Distâncias em linha reta.':'CEP sem coordenadas; comparação por cidade e bairro.');}
     catch{if(live)setGeo('Coordenadas indisponíveis; comparação por cidade e bairro.');}
    }else if(live)setGeo('Sem CEP válido; comparação por cidade e bairro.');
    const [res,links]=await Promise.all([
     ctx.db.rpc('sgi_smart_suggestions',{p_company:target.company,p_branch:target.branch,p_order:target.order??null,p_address:target.manual??{city:target.city,neighborhood:target.neighborhood,cep:target.cep??''},p_booking:target.booking??null}),
     ctx.db.from('logistics_pool_branches').select('pool_id,logistics_pools(id,name,active)').eq('branch_id',target.branch)
    ]);
    if(!live)return;
    if(res.error){setError(res.error.message);setOptions([]);}else setOptions((res.data??[]) as Suggestion[]);
    if(links.error){setError(v=>v||links.error.message);return;}
    const found=(links.data??[]).flatMap(x=>{const item=x.logistics_pools as unknown as {id:string;name:string;active:boolean}|null;return item?.active&&(!target.pool||item.id===target.pool)?[{id:item.id,name:item.name}]:[];});
    setPools(found);setPool(old=>found.some(p=>p.id===old)?old:found[0]?.id??'');
   }catch(e){if(live)setError(e instanceof Error?e.message:'Não foi possível consultar a agenda.');}
   finally{if(live)setLoading(false);}
  };
  void run();return()=>{live=false};
 },[target.company,target.branch,target.order,target.booking,target.cep,target.city,target.neighborhood,refresh]);
 const selectedDate=openNew?date:chosen?.delivery_date;
 const selectedPool=openNew?pool:chosen?.pool_id;
 const valid=!previewOnly&&!!selectedDate&&!!selectedPool&&confirmed&&(!openNew||(canOpen&&Number.isInteger(Number(capacity))&&Number(capacity)>=1&&Number(capacity)<=100))&&(!target.booking||reason.trim().length>=5);
 const openWithoutBooking=async()=>{if(busy||loading||!canOpen||!openNew||!confirmed||!pool||!date||!Number.isInteger(Number(capacity))||Number(capacity)<1||Number(capacity)>100)return;setBusy(true);setError('');try{const {error}=await ctx.db.rpc('sgi_smart_open_day',{p_company:target.company,p_branch:target.branch,p_pool:pool,p_date:date,p_capacity:Number(capacity)});if(error){setError(error.message);return;}ctx.notify('Data aberta, sem reservar o pedido bloqueado.');setOpenNew(false);setRefresh(v=>v+1);}catch{setError('Resultado não confirmado. Recalcule a agenda antes de repetir.');}finally{setBusy(false)}};
 const save=async()=>{
  if(busy||loading||!valid)return;
  setBusy(true);setError('');
  try{
   const {error:err}=await ctx.db.rpc('sgi_smart_schedule',{p_company:target.company,p_branch:target.branch,p_order:target.order??null,p_manual:target.manual??null,p_pool:selectedPool,p_date:selectedDate,p_capacity:openNew?Number(capacity):null,p_booking:target.booking??null,p_expected_date:target.originalDate??null,p_reason:target.booking?reason.trim():null});
   if(err){setError(err.message);return;}
   ctx.notify(target.booking?'Entrega remarcada com histórico.':'Entrega agendada com capacidade reservada.');onSaved(selectedDate!);
  }catch(e){setError(e instanceof Error?e.message:'Resultado não confirmado. Atualize a agenda antes de repetir.');}finally{setBusy(false);}
 };
 return <Panel title={target.booking?'Remarcar entrega':'Assistente de agendamento'} sub="A mesma inteligência para pedidos digitais e entregas avulsas." action={onClose&&<button type="button" className="btn secondary small" disabled={busy} onClick={onClose}>{closeLabel}</button>}>
  <div className="subtle-info"><MapPin size={18}/><div><strong>{target.manual&&('Talão '+target.manual.reference+' · '+titleCaseBR(target.manual.customer)+' — ')}{titleCaseBR(target.neighborhood)} · {titleCaseBR(target.city)}</strong><p>{geo||'Consultando disponibilidade e localização...'}</p></div></div>
  {previewOnly&&<div className="subtle-warning">Planejamento preliminar: o pedido ainda tem bloqueio de liberação. As datas são apenas referências e não podem ser prometidas ou reservadas.</div>}
  {error&&<ErrorBox text={error}/>}
  <div className="toolbar"><span className="tiny-muted">Datas abertas e vagas reais · próximos 45 dias</span><button type="button" className="btn secondary small" disabled={busy||loading} onClick={()=>setRefresh(v=>v+1)}><RefreshCw size={14}/> Recalcular</button></div>
  {loading?<p role="status">Calculando os melhores encaixes...</p>:<>
   {options.length>0&&!options.some(s=>['same_neighborhood','nearby','moderate','same_region'].includes(s.signal))&&<div className="subtle-warning">Nenhuma rota próxima identificada. {canOpen?'Considere abrir uma nova data para este destino.':'Solicite uma nova data à expedição.'} Não é necessário encaixar em rota distante.</div>}
   {canOpen&&<button type="button" disabled={busy} className={'btn '+(openNew?'primary':'secondary')} onClick={()=>{setOpenNew(v=>!v);setChosen(null);setConfirmed(false);}}><CalendarPlus size={17}/> {previewOnly?'Planejar nova data (sem reservar)':'Abrir nova data / rota'}</button>}
   <div className="smart-options">{options.map((s,i)=><button type="button" key={s.id} disabled={busy} className={'smart-option '+(!openNew&&chosen?.id===s.id?'chosen':'')} onClick={()=>{setOpenNew(false);setChosen(s);setConfirmed(false);}}>
    <div><strong>{dateBR(s.delivery_date)} · {s.pool_name}</strong><small>{signalNames[s.signal]??s.signal}{i===0&&['same_neighborhood','nearby','moderate','same_region'].includes(s.signal)?' · Melhor encaixe disponível':''}</small></div>
    <div><strong>{s.used}/{s.capacity}</strong><small>{s.capacity-s.used} vaga(s)</small></div>
    <div><strong>{s.nearest_km==null?'—':Number(s.nearest_km).toFixed(1).replace('.',',')+' km'}</strong><small>CEP mais próximo, linha reta</small></div>
   </button>)}</div>
   {!options.length&&<p className="tiny-muted">Nenhuma data inteligente aberta com vaga. {canOpen?'Aprove uma nova data abaixo.':'Solicite abertura de rota à expedição.'}</p>}
   {openNew&&<div className="form-grid cols3" style={{marginTop:14}}>
    <Field label="Central logística"><select value={pool} onChange={e=>{setPool(e.target.value);setConfirmed(false)}}>{pools.map(p=><option key={p.id} value={p.id}>{p.name}</option>)}</select></Field>
    <Field label="Nova data"><input type="date" value={date} min={today()} max={addDays(today(),180)} onChange={e=>{setDate(e.target.value);setConfirmed(false)}}/></Field>
    <Field label="Capacidade diária aprovada (paradas)"><input type="number" min={1} max={100} value={capacity} onChange={e=>{setCapacity(e.target.value);setConfirmed(false)}} placeholder="Informe a capacidade real"/></Field>
    <div className="subtle-warning smart-wide">Confirme a capacidade operacional da central. Veículo e motorista não são necessários no modo simplificado.</div>
   </div>}
   {target.booking&&<Field label="Motivo da remarcação"><textarea rows={2} maxLength={500} value={reason} onChange={e=>setReason(e.target.value)} placeholder="Informe por que a data foi alterada"/></Field>}
   {((!previewOnly&&(openNew||chosen))||(previewOnly&&openNew))&&<label className="checkbox-bar"><input type="checkbox" checked={confirmed} onChange={e=>setConfirmed(e.target.checked)}/> {previewOnly?'Confirmo a abertura da data para planejamento interno, sem compromisso com o cliente.':'Confirmo a data selecionada e a disponibilidade operacional; o cliente está ciente.'}</label>}
   {previewOnly&&openNew&&<div className="panel-footer"><button type="button" className="btn primary" disabled={busy||!confirmed||!pool||!date||!Number.isInteger(Number(capacity))||Number(capacity)<1||Number(capacity)>100} onClick={()=>void openWithoutBooking()}><CalendarPlus size={17}/> Abrir data sem reservar pedido</button></div>}
   {!previewOnly&&<div className="panel-footer"><button type="button" className="btn primary" disabled={!valid||busy} onClick={()=>void save()}><CalendarCheck size={17}/> {busy?'Reservando...':target.booking?'Confirmar remarcação':'Confirmar agendamento'}</button></div>}
   <p className="tiny-muted">Sugestões não são reservas. O banco valida capacidade e liberação novamente no momento da confirmação. Distâncias não representam trajetos por ruas.</p>
  </>}
 </Panel>;
}
