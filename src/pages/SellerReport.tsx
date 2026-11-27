import {useEffect,useState} from 'react';
import {BarChart3,CalendarDays,Download} from 'lucide-react';
import type {AppContext} from '../lib/types';
import {money,titleCaseBR,dateBR,productDescriptionBR} from '../lib/utils';
import {Empty,PageHead,Panel,Field,ErrorBox} from '../components/UI';
type SellerRow={seller_id:string;seller_name:string;order_count:number;products_gross:number;products_discount:number;products_net:number;legacy_date_count:number};
type Item={id:string;name:string;color:string|null;size_text:string|null;quantity:number;unit_price:number};
type Detail={id:string;order_number:number;seller_name:string;sold_day:string;customer:string;branch_name:string;products_gross:number;products_discount:number;products_net:number;legacy_date:boolean;items:Item[]};
type DetailResult={count:number;gross:number;discount:number;net:number;rows:Detail[]};
const PAGE_SIZE=30;
const csvCell=(v:unknown)=>{const s=String(v??'');return '"'+(/^[\s]*[=+@-]/.test(s)?"'"+s:s).replace(/"/g,'""')+'"'};
const saveCsv=(name:string,rows:unknown[][])=>{const body=rows.map(r=>r.map(csvCell).join(';')).join('\r\n');const url=URL.createObjectURL(new Blob(['\uFEFF'+body],{type:'text/csv;charset=utf-8'}));const a=document.createElement('a');a.href=url;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000)};
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
 const [seller,setSeller]=useState('');const [day,setDay]=useState('');const [page,setPage]=useState(0);const [rate,setRate]=useState('');const [detail,setDetail]=useState<DetailResult|null>(null);const [detailBusy,setDetailBusy]=useState(false);const [detailError,setDetailError]=useState('');
 const validRate=rate.trim()!==''&&Number.isFinite(Number(rate))&&Number(rate)>=0&&Number(rate)<=100;
 useEffect(()=>{let live=true;setDetail(null);setDetailBusy(true);setDetailError('');
 void Promise.resolve(ctx.db.rpc('sgi_seller_report_detail',{p_company:ctx.companyId,p_month:month+'-01',p_seller:seller||null,p_day:day||null,p_offset:page*PAGE_SIZE,p_limit:PAGE_SIZE})).then(({data,error})=>{if(!live)return;if(error){setDetailError(error.message);return;}setDetail(data as DetailResult)}).catch(()=>{if(live)setDetailError('Não foi possível consultar as vendas detalhadas.')}).finally(()=>{if(live)setDetailBusy(false)});return()=>{live=false}},[ctx.companyId,month,seller,day,page,version]);
 const exportDetail=()=>{if(!detail)return;saveCsv('sgi-vendas-detalhadas-'+month+'-pagina-'+(page+1)+'.csv', [['Data','Pedido','Vendedor','Cliente','Loja','Bruto de produtos','Desconto do pedido','Base comissionável','Produtos (quantidade, descrição, cor, medida, preço unitário)'],...detail.rows.map(r=>[r.sold_day,String(r.order_number).padStart(6,'0'),r.seller_name,r.customer,r.branch_name,r.products_gross,r.products_discount,r.products_net,r.items.map(i=>[i.quantity+'× '+i.name,i.color,i.size_text,money(i.unit_price)].filter(Boolean).join(' / ')).join(' | ')])]);};
 const totals=rows.reduce((a,r)=>({count:a.count+Number(r.order_count),gross:a.gross+Number(r.products_gross),discount:a.discount+Number(r.products_discount),net:a.net+Number(r.products_net),legacy:a.legacy+Number(r.legacy_date_count)}),{count:0,gross:0,discount:0,net:0,legacy:0});
 const exportCsv=()=>{
  const body=[['Mês','Vendedor','Pedidos','Produtos brutos','Descontos','Base comissionável'],...rows.map(r=>[month,r.seller_name,r.order_count,r.products_gross,r.products_discount,r.products_net])]
   .map(row=>row.map(csvCell).join(';')).join('\r\n');
  const blob=new Blob(['\uFEFF'+body],{type:'text/csv;charset=utf-8'});
  const url=URL.createObjectURL(blob);const a=document.createElement('a');a.href=url;a.download=`sgi-base-comissao-${month}.csv`;a.click();URL.revokeObjectURL(url);
 };
 return <><PageHead eyebrow="GESTÃO / COMISSÕES" title="Fechamento comercial mensal" desc="Cada mês constitui um ciclo separado. O relatório calcula a base de comissão (produtos − descontos); frete e montagem nunca entram.">
  <label className="field" style={{maxWidth:195}}><span>Mês de competência</span><input type="month" value={month} onChange={e=>{if(e.target.value){setMonth(e.target.value);setDay('');setSeller('');setPage(0)}}} /></label>
  <button className="btn secondary" onClick={()=>setVersion(v=>v+1)}>Atualizar</button>
  <button className="btn secondary" disabled={!rows.length} onClick={exportCsv}><Download size={16}/> Exportar CSV</button>
 </PageHead>
 <div className="subtle-info"><CalendarDays size={17}/> Competência: <strong>{labelMonth(month)}</strong>. Ao trocar o mês, os totais são recalculados, sem apagar o histórico anterior.</div>
 <div className="metric-grid cols3"><div className="metric"><span>Base de comissão · mês</span><strong>{money(totals.net)}</strong><small>Não representa comissão a pagar sem definir percentual</small></div><div className="metric"><span>Pedidos confirmados</span><strong>{totals.count}</strong><small>Somente competência selecionada</small></div><div className="metric"><span>Descontos nos produtos</span><strong>{money(totals.discount)}</strong><small>Frete e montagem excluídos</small></div></div>
 {totals.legacy>0&&<div className="subtle-warning">{totals.legacy} pedido(s) anteriores à implantação da data de confirmação usam a data de criação como aproximação. Validar na homologação do primeiro fechamento.</div>}
 {error&&<div className="subtle-warning">{error}</div>}
 <Panel title={`Base comercial · ${labelMonth(month)}`} sub="Vendedores só visualizam suas próprias vendas; gestores visualizam apenas unidades autorizadas. Comissões percentuais e fechamento auditado serão configurados separadamente.">
  <div className="table-scroll"><table><thead><tr><th>Vendedor</th><th>Pedidos</th><th>Bruto de produtos</th><th>Descontos</th><th>Base de comissão</th><th>Ações</th></tr></thead><tbody>{rows.map(r=><tr key={r.seller_id}><td><div className="table-ident"><div className="table-avatar"><BarChart3 size={16}/></div><strong>{titleCaseBR(r.seller_name)}</strong></div></td><td>{r.order_count}</td><td>{money(r.products_gross)}</td><td>{money(r.products_discount)}</td><td><strong className="green-text">{money(r.products_net)}</strong></td><td><button className="btn secondary small" onClick={()=>{setSeller(r.seller_id);setDay('');setPage(0);document.getElementById('seller-detail')?.scrollIntoView({block:'start',behavior:'smooth'})}}>Ver vendas</button></td></tr>)}</tbody></table></div>
  {!busy&&!rows.length&&<Empty title="Nenhuma venda na competência escolhida" description="O próximo mês começa zerado automaticamente, preservando o histórico dos meses anteriores."/>}
 </Panel>
 <section id="seller-detail"><Panel title="Vendas detalhadas por pedido" sub="Filtre por vendedor e dia da competência. Cada pedido mantém a base líquida original; frete e montagem não entram.">
 <div className="form-grid cols3">
 <Field label="Vendedor"><select value={seller} onChange={e=>{setSeller(e.target.value);setPage(0)}}><option value="">Todos autorizados</option>{rows.map(r=><option key={r.seller_id} value={r.seller_id}>{titleCaseBR(r.seller_name)}</option>)}</select></Field>
 <Field label="Dia (opcional)"><input type="date" min={month+'-01'} max={month+'-'+String(new Date(Number(month.slice(0,4)),Number(month.slice(5)),0).getDate()).padStart(2,'0')} value={day} onChange={e=>{setDay(e.target.value);setPage(0)}}/></Field>
 <Field label="Percentual simulado (%)" help="Não grava regras de comissão nem gera pagamento."><input type="number" min={0} max={100} step="0.01" value={rate} onChange={e=>setRate(e.target.value)} placeholder="Ex.: 3"/></Field>
 </div>
 {detailError&&<ErrorBox text={detailError}/>}
 {detailBusy?<p role="status">Consultando vendas...</p>:detail&&<>
 <div className="metrics-strip" style={{marginTop:18}}><div><span>Pedidos no filtro</span><strong>{detail.count}</strong></div><div><span>Base líquida no filtro</span><strong>{money(detail.net)}</strong></div><div><span>Comissão simulada</span><strong>{validRate?money(Number(detail.net)*Number(rate)/100):'—'}</strong></div></div>
 <div className="toolbar"><button className="btn secondary small" disabled={!detail.rows.length} onClick={exportDetail}><Download size={16}/> Exportar página CSV</button><button className="btn secondary small" onClick={()=>{setSeller('');setDay('');setPage(0)}}>Limpar filtros</button></div>
 <div className="table-scroll"><table><thead><tr><th>Data / Pedido</th><th>Vendedor / Cliente</th><th>Produtos vendidos</th><th>Bruto</th><th>Desconto</th><th>Base líquida</th>{validRate&&<th>Comissão simulada</th>}</tr></thead><tbody>{detail.rows.map(r=><tr key={r.id}><td><strong>#{String(r.order_number).padStart(6,'0')}</strong><small>{dateBR(r.sold_day)}{r.legacy_date?' (data aproximada)':''}</small><small>{r.branch_name}</small></td><td><strong>{titleCaseBR(r.seller_name)}</strong><small>{titleCaseBR(r.customer)}</small></td><td>{r.items.map(i=><div key={i.id} style={{marginBottom:8}}><strong>{i.quantity}× {productDescriptionBR(i.name)}</strong><small>{[i.color,i.size_text,money(i.unit_price)+' / un.'].filter(Boolean).join(' · ')}</small></div>)}</td><td>{money(r.products_gross)}</td><td>{money(r.products_discount)}</td><td><strong>{money(r.products_net)}</strong></td>{validRate&&<td>{money(Number(r.products_net)*Number(rate)/100)}</td>}</tr>)}</tbody></table></div>
 {!detail.rows.length&&<Empty title="Nenhum pedido no filtro"/>}
 <div className="pager"><span>{detail.count} pedido(s) · Página {page+1} de {Math.max(1,Math.ceil(detail.count/PAGE_SIZE))}</span><div><button className="btn secondary small" disabled={page===0} onClick={()=>setPage(p=>p-1)}>Anterior</button><button className="btn secondary small" disabled={(page+1)*PAGE_SIZE>=detail.count} onClick={()=>setPage(p=>p+1)}>Próxima</button></div></div>
 </>}
 <p className="tiny-muted">A simulação usa um percentual único para os pedidos filtrados e não constitui fechamento ou obrigação de pagamento. Cancelados e rascunhos não entram. O CSV detalhado exporta somente a página visível, evitando duplicar valores por item.</p>
 </Panel></section></>;
}
