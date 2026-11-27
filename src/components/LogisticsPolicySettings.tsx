import {useEffect,useState} from 'react';
import {ShieldCheck,Truck,UserRound,Package} from 'lucide-react';
import type {AppContext} from '../lib/types';
import {Panel,ErrorBox} from './UI';
export type LogisticsPolicy={require_vehicle:boolean;require_driver:boolean;enforce_vehicle_stops:boolean;revision:number};
export function LogisticsPolicySettings({ctx}:{ctx:AppContext}){
 const [policy,setPolicy]=useState<LogisticsPolicy|null>(null);
 const [draft,setDraft]=useState<LogisticsPolicy|null>(null);
 const [busy,setBusy]=useState(false);const [error,setError]=useState('');const [revision,setRevision]=useState(0);
 useEffect(()=>{let live=true;setPolicy(null);setDraft(null);setError('');void ctx.db.rpc('sgi_get_logistics_policy',{p_tenant:ctx.tenantId}).then(({data,error})=>{if(!live)return;if(error){setError(error.message);return;}setPolicy(data);setDraft(data)});return()=>{live=false}},[ctx.tenantId,revision]);
 const save=async()=>{if(!draft||!policy||busy)return;setBusy(true);setError('');try{const {data,error}=await ctx.db.rpc('sgi_set_logistics_policy',{p_tenant:ctx.tenantId,p_revision:policy.revision,p_vehicle:draft.require_vehicle,p_driver:draft.require_driver,p_stops:draft.enforce_vehicle_stops});if(error){setError(error.message);return;}setPolicy(data);setDraft(data);ctx.notify('Parâmetros logísticos salvos e auditados.');}finally{setBusy(false)}};
 return <Panel title="Parâmetros da operação logística" sub="Configure as exigências do romaneio sem vincular o agendamento à frota. As regras se aplicam aos novos romaneios de todo o grupo.">
 {error&&<ErrorBox text={error}/>}
 {!draft?<div className="toolbar"><span>{error?'Consulta indisponível':'Carregando parâmetros...'}</span><button className="btn secondary" onClick={()=>setRevision(v=>v+1)}>Atualizar</button></div>:<>
 <div className="subtle-info"><ShieldCheck size={18}/><div><strong>{draft.require_vehicle||draft.require_driver?'Modo configurado':'Modo simplificado'}</strong><p>Pedidos digitais e talões continuam disponíveis. O limite de entregas por data da central permanece ativo.</p></div></div>
 <div className="form-stack" style={{marginTop:16}}>
 <label className="checkbox-bar"><input type="checkbox" disabled={busy} checked={draft.require_vehicle} onChange={e=>setDraft(v=>v?{...v,require_vehicle:e.target.checked,enforce_vehicle_stops:e.target.checked&&v.enforce_vehicle_stops}:v)}/><span><strong>Exigir veículo no romaneio</strong><br/>Quando desativado, o veículo é opcional.</span></label>
 <label className="checkbox-bar"><input type="checkbox" disabled={busy} checked={draft.require_driver} onChange={e=>setDraft(v=>v?{...v,require_driver:e.target.checked}:v)}/><span><strong>Exigir motorista no romaneio</strong><br/>Quando desativado, o motorista é opcional.</span></label>
 <label className="checkbox-bar"><input type="checkbox" disabled={busy||!draft.require_vehicle} checked={draft.enforce_vehicle_stops} onChange={e=>setDraft(v=>v?{...v,enforce_vehicle_stops:e.target.checked}:v)}/><span><strong>Controlar limite de paradas por veículo</strong><br/>Depende da exigência de veículo e da capacidade de paradas cadastrada.</span></label>
 <div className="subtle-info"><Package size={18}/><div><strong>Cubagem e peso — desativados</strong><p>Controle por volume embalado, dimensões, peso e capacidade física ainda em preparação. Não bloqueia agendamentos ou romaneios; a ativação dependerá da implementação e dos cadastros reais.</p></div></div>
 <div className="subtle-info"><Truck size={18}/><div><strong>Agendamento inteligente e entrega avulsa — sempre disponíveis</strong><p>Proximidade, capacidade diária, auditoria e bloqueios financeiros/de fabricação permanecem protegidos. Não são desativados por esta configuração.</p></div></div>
 <div className="panel-footer"><button type="button" className="btn secondary" disabled={busy} onClick={()=>setRevision(v=>v+1)}>Recarregar</button><button type="button" className="btn primary" disabled={busy||JSON.stringify(draft)===JSON.stringify(policy)} onClick={()=>void save()}><ShieldCheck size={16}/> {busy?'Salvando...':'Salvar parâmetros'}</button></div>
 </div></>}
 </Panel>;
}
