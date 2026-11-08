import {useEffect,useState} from 'react';
import {CreditCard,CheckCircle2,Wallet} from 'lucide-react';
import type {AppContext} from '../lib/types';
import {dateBR,money,today} from '../lib/utils';
import {Empty,PageHead,Pager,Panel,Status} from '../components/UI';

type FinancialOrder={id:string;order_number:number;created_at:string;customer_snapshot:{name?:string};
 grand_total:number;received_total:number;products_gross:number;products_discount:number;financial_status:string;due_date:string|null;commercial_status:string};

export function Finance({ctx}:{ctx:AppContext}){
 const [rows,setRows]=useState<FinancialOrder[]>([]);
 const [page,setPage]=useState(0);const [total,setTotal]=useState(0);
 const [status,setStatus]=useState('all');const [version,setVersion]=useState(0);
 useEffect(()=>{const interval=window.setInterval(()=>setVersion(v=>v+1),30000);return()=>window.clearInterval(interval)},[]);
 useEffect(()=>{setPage(0)},[ctx.companyId]);
 useEffect(()=>{let live=true;const run=async()=>{
  let q=ctx.db.from('orders').select('id,order_number,created_at,customer_snapshot,grand_total,received_total,products_gross,products_discount,financial_status,due_date,commercial_status',{count:'exact'})
   .eq('company_id',ctx.companyId).eq('commercial_status','confirmed').is('deleted_at',null).order('created_at',{ascending:false}).range(page*10,page*10+9);
  if(status==='paid'||status==='partial'||status==='unpaid')q=q.eq('financial_status',status);
  if(status==='overdue')q=q.neq('financial_status','paid').lt('due_date',today());
  const {data,error,count}=await q;
  if(!live)return;
  if(error){ctx.notify(error.message,'error');return;}
  setRows((data??[]) as FinancialOrder[]);setTotal(count??0);
 };void run();return()=>{live=false}},[ctx.companyId,page,status,version]);
 const totalSales=rows.reduce((a,r)=>a+Number(r.grand_total),0);
 const received=rows.reduce((a,r)=>a+Number(r.received_total),0);
 const pending=rows.reduce((a,r)=>a+Math.max(0,Number(r.grand_total)-Number(r.received_total)),0);
 return <><PageHead eyebrow="FINANCEIRO / MOVIMENTAÇÃO COMERCIAL" title="Financeiro" desc="Todas as vendas confirmadas, mesmo as quitadas no ato, com saldos e recebimentos vinculados ao pedido."><button className="btn secondary" onClick={()=>setVersion(v=>v+1)}>Atualizar</button></PageHead>
 <div className="metric-grid cols3">
  <div className="metric"><span>Pedidos da página</span><strong>{money(totalSales)}</strong><small>Valor total incluindo frete e montagem</small></div>
  <div className="metric"><span>Recebido · página</span><strong>{money(received)}</strong><small>Valores registrados pelos operadores, sujeitos à conferência</small></div>
  <div className="metric"><span>Saldo restante · página</span><strong>{money(pending)}</strong><small>Não representa o saldo consolidado da empresa</small></div>
 </div>
 <Panel title="Livro de pedidos e recebimentos" sub="A lista inclui vendas quitadas, parcialmente pagas e sem recebimento. Abra cada pedido para consultar as formas e a trilha de pagamentos.">
  <div className="toolbar"><select className="filter-select" value={status} onChange={e=>{setStatus(e.target.value);setPage(0)}}>
   <option value="all">Todas as vendas</option><option value="paid">Quitadas</option><option value="partial">Parcialmente pagas</option><option value="unpaid">Sem pagamento</option><option value="overdue">Saldos vencidos</option>
  </select><span className="tiny-muted">{total} venda(s) no filtro</span></div>
  <div className="table-scroll"><table><thead><tr><th>Pedido</th><th>Cliente</th><th>Data</th><th>Total</th><th>Recebido</th><th>Saldo</th><th>Situação</th><th></th></tr></thead><tbody>
   {rows.map(r=>{const saldo=Math.max(0,Number(r.grand_total)-Number(r.received_total));const overdue=saldo>0&&r.due_date!==null&&r.due_date<today();return <tr key={r.id}>
    <td><strong>#{String(r.order_number).padStart(6,'0')}</strong></td><td>{r.customer_snapshot?.name??'Cliente'}</td>
    <td>{dateBR(r.created_at)}</td><td><strong>{money(r.grand_total)}</strong></td><td>{money(r.received_total)}</td>
    <td><strong className={overdue?'danger-text':''}>{money(saldo)}</strong>{r.due_date&&<small>Venc. {dateBR(r.due_date)}</small>}</td>
    <td><Status value={r.financial_status}/>{overdue&&<small className="danger-text">Vencido</small>}</td>
    <td><button className="btn secondary small" onClick={()=>ctx.go('order-detail',r.id)}>{saldo===0?<CheckCircle2 size={15}/>:<CreditCard size={15}/>} Abrir</button></td>
   </tr>})}
  </tbody></table></div>
  {!rows.length&&<Empty title="Sem vendas neste filtro" description="As vendas confirmadas aparecerão aqui, inclusive quando o pagamento estiver quitado."/>}
  <Pager page={page} total={total} size={10} onChange={setPage}/>
 </Panel>
 <div className="help-card"><Wallet size={20}/><h3>Conciliação financeira</h3><p>O status “Quitado” significa que o recebimento foi registrado no SGI. A conferência de Pix e cartões com extratos e operadoras permanece necessária.</p></div>
 </>;
}
