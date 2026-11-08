import {useEffect,useState} from 'react';
import {MapPin,Plus,RotateCcw,Trash2,Check,Edit3,Layers3} from 'lucide-react';
import type {AppContext} from '../lib/types';
import {Field,Panel} from './UI';

type ZoneArea={id:string;city:string;neighborhood:string};
type Zone={id:string;name:string;active:boolean;delivery_region_areas:ZoneArea[]};
type ObservedLocation={city:string;neighborhood:string;orders:number};

const neighborhoodLines=(text:string,city:string)=>[...new Set(text.split(/\r?\n|;|,/g).map(s=>s.trim()).filter(Boolean))]
 .map(neighborhood=>({city:city.trim(),neighborhood}));

export function RegionsManager({ctx,onChange}:{ctx:AppContext;onChange:()=>void}){
 const [zones,setZones]=useState<Zone[]>([]);
 const [observed,setObserved]=useState<ObservedLocation[]>([]);
 const [name,setName]=useState('');const [city,setCity]=useState('Recife');
 const [neighborhoods,setNeighborhoods]=useState('');
 const [selected,setSelected]=useState('');const [editName,setEditName]=useState('');
 const [areaCity,setAreaCity]=useState('Recife');const [areasToAdd,setAreasToAdd]=useState('');
 const [busy,setBusy]=useState(false);const [refresh,setRefresh]=useState(0);
 useEffect(()=>{
  let live=true;
  void Promise.all([
    ctx.db.from('delivery_regions').select('id,name,active,delivery_region_areas(id,city,neighborhood)').eq('tenant_id',ctx.tenantId).order('name'),
    ctx.db.rpc('sgi_discover_neighborhoods',{p_tenant:ctx.tenantId})
  ]).then(([zonesRes,discoverRes])=>{
   if(!live)return;
   if(zonesRes.error)ctx.notify(zonesRes.error.message,'error');
   if(discoverRes.error)ctx.notify(discoverRes.error.message,'error');
   setZones((zonesRes.data??[]) as Zone[]);
   setObserved(Array.isArray(discoverRes.data)?discoverRes.data as ObservedLocation[]:[]);
  });
  return()=>{live=false};
 },[ctx.tenantId,refresh]);
 const chosen=zones.find(z=>z.id===selected);
 const run=async(action:string,regionId:string|null,zoneName:string|null,locations:{city:string;neighborhood:string}[],success:string)=>{
  setBusy(true);
  try{
   const {error}=await ctx.db.rpc('sgi_manage_region',{p_tenant:ctx.tenantId,p_region:regionId,p_action:action,p_name:zoneName,p_locations:locations});
   if(error){ctx.notify(error.message,'error');return false;}
   ctx.notify(success);setRefresh(v=>v+1);onChange();return true;
  }finally{setBusy(false);}
 };
 const create=async()=>{
  if(!name.trim()||!city.trim()||!neighborhoods.trim())return;
  const ok=await run('create',null,name.trim(),neighborhoodLines(neighborhoods,city),'Zona criada com bairros vinculados.');
  if(ok){setName('');setNeighborhoods('');}
 };
 const add=async()=>{
  if(!chosen||!areasToAdd.trim()||!areaCity.trim())return;
  const ok=await run('add_areas',chosen.id,null,neighborhoodLines(areasToAdd,areaCity),'Bairros adicionados à mesma região.');
  if(ok)setAreasToAdd('');
 };
 const useObserved=async(loc:ObservedLocation)=>{
  if(!chosen)return;
  await run('add_areas',chosen.id,null,[{city:loc.city,neighborhood:loc.neighborhood}], 'Bairro descoberto pelos pedidos foi vinculado à zona selecionada.');
 };
 return <Panel title="Zonas de entrega e bairros" sub="Uma região pode reunir vários bairros. A agenda continua condicionada às vagas reais da frota.">
  <div className="form-stack">
   <div className="subheading">Nova zona de entrega</div>
   <Field label="Nome da zona"><input value={name} onChange={e=>setName(e.target.value)} placeholder="Ex.: Zona Sul — Rota 01"/></Field>
   <Field label="Cidade"><input value={city} onChange={e=>setCity(e.target.value)}/></Field>
   <Field label="Bairros (um por linha)"><textarea rows={3} value={neighborhoods} onChange={e=>setNeighborhoods(e.target.value)} placeholder={'Boa Viagem\nPina\nImbiribeira'} /></Field>
   <button className="btn secondary" disabled={busy||!name.trim()||!city.trim()||!neighborhoods.trim()} onClick={create}><Plus size={16}/> Criar zona e vincular bairros</button>
  </div>
  <div className="soft-divider"/>
  <div className="subheading">Zonas existentes</div>
  <div className="form-stack">
   <Field label="Selecionar zona para editar"><select value={selected} onChange={e=>{setSelected(e.target.value);setEditName(zones.find(z=>z.id===e.target.value)?.name??'')}}><option value="">Selecione uma zona</option>{zones.map(z=><option key={z.id} value={z.id}>{z.name}{z.active?'':' (inativa)'}</option>)}</select></Field>
   {chosen&&<>
    <div className="subtle-info">{chosen.delivery_region_areas?.length??0} bairro(s) vinculado(s) · {chosen.active?'Zona ativa':'Zona desativada'}</div>
    <div className="zone-area-list">{(chosen.delivery_region_areas??[]).map(a=><div className="zone-area-chip" key={a.id}><MapPin size={13}/><span>{a.neighborhood} — {a.city}</span><button type="button" disabled={busy||!chosen.active} aria-label={`Remover ${a.neighborhood}`} title="Desvincular bairro" onClick={()=>{if(window.confirm(`Remover ${a.neighborhood} desta zona?`))void run('remove_areas',chosen.id,null,[{city:a.city,neighborhood:a.neighborhood}], 'Bairro desvinculado com auditoria.')}}><Trash2 size={14}/></button></div>)}</div>
    <Field label="Renomear zona"><input value={editName} onChange={e=>setEditName(e.target.value)}/></Field>
    <button className="btn secondary small" disabled={busy||!editName.trim()} onClick={()=>void run('rename',chosen.id,editName,[],'Zona renomeada.')}><Edit3 size={14}/> Salvar novo nome</button>
    {chosen.active&&<><Field label="Cidade dos novos bairros"><input value={areaCity} onChange={e=>setAreaCity(e.target.value)}/></Field>
     <Field label="Adicionar bairros (um por linha)"><textarea rows={3} value={areasToAdd} onChange={e=>setAreasToAdd(e.target.value)} placeholder={'Pina\nImbiribeira'}/></Field>
     <button className="btn secondary small" disabled={busy||!areasToAdd.trim()} onClick={add}><Plus size={14}/> Adicionar vários bairros</button></>}
    <button className={'btn small '+(chosen.active?'danger':'secondary')} disabled={busy} onClick={()=>{
      const action=chosen.active?'archive':'restore';
      if(window.confirm(chosen.active?'Desativar região? Reservas futuras precisam ser removidas antes.':'Reativar a zona?'))
       void run(action,chosen.id,null,[],chosen.active?'Zona arquivada, com histórico preservado.':'Zona reativada.');
    }}>{chosen.active?<Trash2 size={14}/>:<RotateCcw size={14}/>} {chosen.active?'Desativar zona':'Reativar zona'}</button>
   </>}
  </div>
  <div className="soft-divider"/>
  <div className="subheading"><Layers3 size={16}/> Bairros identificados nos pedidos</div>
  <p className="tiny-muted">O sistema aprende quais bairros têm pedidos, sem presumir que sejam vizinhos. Selecione uma zona acima e aprove a vinculação.</p>
  <div className="item-list">{observed.map(loc=><div key={`${loc.city}-${loc.neighborhood}`}><strong>{loc.neighborhood} / {loc.city}</strong><small>{loc.orders} pedido(s) sem região mapeada</small><button className="btn secondary small" disabled={busy||!chosen?.active} onClick={()=>void useObserved(loc)}><Check size={14}/> Vincular à zona selecionada</button></div>)}{observed.length===0&&<p className="tiny-muted">Nenhum bairro novo aguardando classificação.</p>}</div>
 </Panel>;
}
