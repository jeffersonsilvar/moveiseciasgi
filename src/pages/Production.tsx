import {useEffect,useState} from 'react';
import {Factory,PackageCheck,Undo2,ShieldAlert} from 'lucide-react';
import type {AppContext} from '../lib/types';
import {dateBR} from '../lib/utils';
import {Empty,PageHead,Panel,Status} from '../components/UI';
type ProductLine={id:string;name:string;sku:string|null;color:string|null;quantity:number;availability_status:string;production_eta:string|null};
type ProdOrder={id:string;order_number:number;company_id:string;customer_snapshot:{name?:string};commercial_status:string;created_at:string;order_items:ProductLine[]};
export function Production({ctx}:{ctx:AppContext}){
 const [orders,setOrders]=useState<ProdOrder[]>([]);const [busy,setBusy]=useState(false);const [version,setVersion]=useState(0);const [eta,setEta]=useState<Record<string,string>>({});
 const [revertItem,setRevertItem]=useState<string|null>(null);const [reason,setReason]=useState('');const [revertStatus,setRevertStatus]=useState('manufacturing');
 useEffect(()=>{const interval=window.setInterval(()=>setVersion(v=>v+1),30000);return()=>window.clearInterval(interval)},[]);
 useEffect(()=>{let live=true;void ctx.db.from('orders').select('id,order_number,company_id,customer_snapshot,commercial_status,created_at,order_items(id,name,sku,color,quantity,availability_status,production_eta)').eq('company_id',ctx.companyId).eq('commercial_status','confirmed').order('created_at',{ascending:false}).limit(150).then(({data,error})=>{if(!live)return;if(error)ctx.notify(error.message,'error');setOrders((data??[]) as ProdOrder[])});return()=>{live=false}},[ctx.companyId,version]);
 const pending=orders.flatMap(o=>o.order_items.filter(i=>i.availability_status!=='ready').map(i=>({order:o,item:i})));
 const release=async(itemId:string,ready:boolean)=>{
  const item=orders.flatMap(o=>o.order_items).find(i=>i.id===itemId);if(!item)return;
  setBusy(true);const {error}=await ctx.db.rpc('sgi_change_item_availability',{p_item:itemId,p_status:ready?'ready':item.availability_status,p_reason:ready?'Produto conferido e disponível pela fabricação.':'Previsão atualizada pelo setor de fabricação.',p_eta:ready?null:eta[itemId]||item.production_eta});
  setBusy(false);if(error)ctx.notify(error.message,'error');else{ctx.notify(ready?'Produto liberado para expedição.':'Previsão registrada.');setVersion(v=>v+1)}
 };
 const revert=async()=>{if(!revertItem||reason.trim().length<8)return;
  if(!window.confirm('Confirmar reversão? Se o pedido estiver apenas agendado, a data será cancelada e a vaga devolvida.'))return;
  setBusy(true);const {data,error}=await ctx.db.rpc('sgi_change_item_availability',{p_item:revertItem,p_status:revertStatus,p_reason:reason.trim(),p_eta:null});setBusy(false);
  if(error){ctx.notify(error.message,'error');return;}
  ctx.notify((data as {booking_cancelled?:boolean}|null)?.booking_cancelled?'Liberação desfeita. Agendamento cancelado e vaga devolvida.':'Liberação corrigida com auditoria.');
  setRevertItem(null);setReason('');setVersion(v=>v+1);
 };
 const readyItems=orders.flatMap(o=>o.order_items.filter(i=>i.availability_status==='ready').map(item=>({order:o,item}))); 
 return <><PageHead eyebrow="OPERAÇÃO / DISPONIBILIDADE" title="Fabricação e encomendas" desc="Cada item precisa estar disponível antes de qualquer carga ou romaneio."><button className="btn secondary" onClick={()=>setVersion(v=>v+1)}>Atualizar</button></PageHead><div className="metric-grid cols3"><div className="metric"><span>Itens aguardando</span><strong>{pending.length}</strong><small>Bloqueiam a movimentação logística</small></div><div className="metric"><span>Pedidos em análise</span><strong>{new Set(pending.map(i=>i.order.id)).size}</strong><small>Dentro dos 150 pedidos mais recentes</small></div><div className="metric"><span>Controle</span><strong><Factory size={25}/></strong><small>Liberação individual auditada</small></div></div>
 <Panel title="Fila de disponibilidade" sub="Somente o setor autorizado pode liberar itens."><div className="table-scroll"><table><thead><tr><th>Pedido</th><th>Produto</th><th>Qtd</th><th>Situação</th><th>Previsão</th><th>Próxima ação</th></tr></thead><tbody>{pending.map(({order:o,item:i})=><tr key={i.id}><td><button className="link-strong" onClick={()=>ctx.go('order-detail',o.id)}>#{o.order_number}</button><small>{o.customer_snapshot.name}</small></td><td><strong>{i.name}</strong><small>{i.sku} · {i.color}</small></td><td>{i.quantity}</td><td><Status value={i.availability_status}/></td><td><input type="date" className="compact-input" value={eta[i.id]??i.production_eta??''} onChange={e=>setEta(old=>({...old,[i.id]:e.target.value}))}/></td><td><div className="action-pair"><button className="btn secondary small" disabled={busy||!ctx.canProduction||!(eta[i.id]||i.production_eta)} onClick={()=>release(i.id,false)}>Registrar previsão</button><button className="btn primary small" disabled={busy||!ctx.canProduction} onClick={()=>release(i.id,true)}><PackageCheck size={15}/> Liberar</button></div></td></tr>)}</tbody></table></div>{!pending.length&&<Empty title="Tudo liberado" description="Não há itens de fabricação ou encomenda pendentes nos pedidos consultados."/>}</Panel>
 <Panel title="Itens liberados · corrigir engano" sub="A reversão retorna o pedido para a fila logística e cancela reservas ainda não carregadas, preservando a auditoria.">
  <div className="table-scroll"><table><thead><tr><th>Pedido</th><th>Produto</th><th>Situação</th><th>Ação</th></tr></thead><tbody>
   {readyItems.map(({order:o,item:i})=><tr key={i.id}><td>#{o.order_number}</td><td><strong>{i.name}</strong><small>{i.sku??''}</small></td><td><Status value={i.availability_status}/></td>
    <td><button className="btn secondary small" disabled={busy||!ctx.canProduction} onClick={()=>{setRevertItem(i.id);setReason('');setRevertStatus('manufacturing')}}><Undo2 size={14}/> Desfazer liberação</button></td></tr>)}
  </tbody></table></div>
  {!readyItems.length&&<Empty title="Nenhum item liberado" description="A lista mostrará os itens disponíveis para eventual correção."/>}
  {revertItem&&<div className="subtle-warning" style={{marginTop:14}}><div className="subheading"><ShieldAlert size={16}/> Reverter disponibilidade</div>
   <label className="field"><span>Retornar para</span><select value={revertStatus} onChange={e=>setRevertStatus(e.target.value)}><option value="manufacturing">Em fabricação</option><option value="ordered">Sob encomenda</option><option value="blocked">Bloqueado</option></select></label>
   <label className="field"><span>Motivo obrigatório (mínimo 8 caracteres)</span><textarea rows={3} value={reason} onChange={e=>setReason(e.target.value)} placeholder="Ex.: Liberação anterior registrada por engano"/></label>
   <div className="action-pair"><button className="btn secondary small" onClick={()=>setRevertItem(null)}>Voltar</button><button className="btn danger small" disabled={busy||reason.trim().length<8} onClick={revert}>Confirmar correção</button></div>
   <p className="tiny-muted">Se houver carga em rota ou mercadoria entregue, a operação será bloqueada até regularização física pela expedição.</p>
  </div>}
 </Panel></>;
}
