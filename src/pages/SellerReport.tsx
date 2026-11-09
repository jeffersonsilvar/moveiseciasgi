import {useEffect,useState} from 'react';
import {BarChart3,CalendarDays,Download} from 'lucide-react';
import type {AppContext} from '../lib/types';
import {money} from '../lib/utils';
import {Empty,PageHead,Panel} from '../components/UI';
type SellerRow={seller_id:string;seller_name:string;order_count:number;products_gross:number;products_discount:number;products_net:number;legacy_date_count:number};
const monthNow=()=>new Intl.DateTimeFormat('en-CA',{timeZone:'America/Recife',year:'numeric',month:'2-digit'}).format(new Date()).slice(0,7);
const labelMonth=(month:string)=>new Date(month+'-02T12:00:00').toLocaleDateString('pt-BR',{month:'long',year:'numeric',timeZone:'UTC'});
export function SellerReport({ctx}:{ctx:AppContext}){
 const [month,setMonth]=useState(monthNow);const [rows,setRows]=useState<SellerRow[]>([]);const [busy,setBusy]=useState(true);
 const [version,setVersion]=useState(0);const [error,setError]=useState('');
 useEffect(()=>{let alive=true;setBusy(true);setError('');
  void ctx.db.rpc('sgi_seller_monthly_report',{p_company:ctx.companyId,p_month:month+'-01'}).then(({data,error:err})=>{
   if(!alive)return;setBusy(false);if(err){setError(err.message);setRows([]);return;}
   setRows((data??[]) as SellerRow[]);
  });return()=>{alive=false};
 },[ctx.companyId,month,version]);
 const totals=rows.reduce((a,r)=>({count:a.count+Number(r.order_count),gross:a.gross+Number(r.products_gross),discount:a.discount+Number(r.products_discount),net:a.net+Number(r.products_net),legacy:a.legacy+Number(r.legacy_date_count)}),{count:0,gross:0,discount:0,net:0,legacy:0});
 const exportCsv=()=>{
  const body=[['Mês','Vendedor','Pedidos','Produtos brutos','Descontos','Base comissionável'],...rows.map(r=>[month,r.seller_name,r.order_count,r.products_gross,r.products_discount,r.products_net])]
   .map(row=>row.map(v=>'"'+String(v).replace(/"/g,'""')+'"').join(';')).join('\r\n');
  const blob=new Blob(['\uFEFF'+body],{type:'text/csv;charset=utf-8'});
  const url=URL.createObjectURL(blob);const a=document.createElement('a');a.href=url;a.download=`sgi-base-comissao-${month}.csv`;a.click();URL.revokeObjectURL(url);
 };
 return <><PageHead eyebrow="GESTÃO / COMISSÕES" title="Fechamento comercial mensal" desc="Cada mês constitui um ciclo separado. O relatório calcula a base de comissão (produtos − descontos); frete e montagem nunca entram.">
  <label className="field" style={{maxWidth:195}}><span>Mês de competência</span><input type="month" value={month} onChange={e=>setMonth(e.target.value)} /></label>
  <button className="btn secondary" onClick={()=>setVersion(v=>v+1)}>Atualizar</button>
  <button className="btn secondary" disabled={!rows.length} onClick={exportCsv}><Download size={16}/> Exportar CSV</button>
 </PageHead>
 <div className="subtle-info"><CalendarDays size={17}/> Competência: <strong>{labelMonth(month)}</strong>. Ao trocar o mês, os totais são recalculados, sem apagar o histórico anterior.</div>
 <div className="metric-grid cols3"><div className="metric"><span>Base de comissão · mês</span><strong>{money(totals.net)}</strong><small>Não representa comissão a pagar sem definir percentual</small></div><div className="metric"><span>Pedidos confirmados</span><strong>{totals.count}</strong><small>Somente competência selecionada</small></div><div className="metric"><span>Descontos nos produtos</span><strong>{money(totals.discount)}</strong><small>Frete e montagem excluídos</small></div></div>
 {totals.legacy>0&&<div className="subtle-warning">{totals.legacy} pedido(s) anteriores à implantação da data de confirmação usam a data de criação como aproximação. Validar na homologação do primeiro fechamento.</div>}
 {error&&<div className="subtle-warning">{error}</div>}
 <Panel title={`Base comercial · ${labelMonth(month)}`} sub="Vendedores só visualizam suas próprias vendas; gestores visualizam apenas unidades autorizadas. Comissões percentuais e fechamento auditado serão configurados separadamente.">
  <div className="table-scroll"><table><thead><tr><th>Vendedor</th><th>Pedidos</th><th>Bruto de produtos</th><th>Descontos</th><th>Base de comissão</th></tr></thead><tbody>{rows.map(r=><tr key={r.seller_id}><td><div className="table-ident"><div className="table-avatar"><BarChart3 size={16}/></div><strong>{r.seller_name}</strong></div></td><td>{r.order_count}</td><td>{money(r.products_gross)}</td><td>{money(r.products_discount)}</td><td><strong className="green-text">{money(r.products_net)}</strong></td></tr>)}</tbody></table></div>
  {!busy&&!rows.length&&<Empty title="Nenhuma venda na competência escolhida" description="O próximo mês começa zerado automaticamente, preservando o histórico dos meses anteriores."/>}
 </Panel></>;
}
