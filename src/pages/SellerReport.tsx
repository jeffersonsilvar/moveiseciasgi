import {useEffect,useState} from 'react';
import {BarChart3} from 'lucide-react';
import type {AppContext} from '../lib/types';
import {money} from '../lib/utils';
import {Empty,PageHead,Panel} from '../components/UI';
type SellerRow={seller_id:string;seller_name:string;order_count:number;products_gross:number;products_discount:number;products_net:number};
export function SellerReport({ctx}:{ctx:AppContext}){
 const [rows,setRows]=useState<SellerRow[]>([]);const [busy,setBusy]=useState(true);const [version,setVersion]=useState(0);
 useEffect(()=>{let alive=true;void ctx.db.rpc('sgi_seller_report',{p_company:ctx.companyId}).then(({data,error})=>{if(!alive)return;if(error)ctx.notify(error.message,'error');setRows((data??[]) as SellerRow[]);setBusy(false)});return()=>{alive=false}},[ctx.companyId,version]);
 const totals=rows.reduce((a,r)=>({count:a.count+Number(r.order_count),gross:a.gross+Number(r.products_gross),discount:a.discount+Number(r.products_discount),net:a.net+Number(r.products_net)}),{count:0,gross:0,discount:0,net:0});
 return <><PageHead eyebrow="GESTÃO / PERFORMANCE" title="Vendas por vendedor" desc="Indicador oficial: produtos vendidos menos descontos. Nunca soma frete ou montagem."><button className="btn secondary" onClick={()=>setVersion(v=>v+1)}>Atualizar</button></PageHead>
 <div className="metric-grid cols3"><div className="metric"><span>Venda líquida</span><strong>{money(totals.net)}</strong><small>Produtos líquidos, sem serviços</small></div><div className="metric"><span>Pedidos confirmados</span><strong>{totals.count}</strong><small>Não inclui rascunhos/cancelados</small></div><div className="metric"><span>Descontos concedidos</span><strong>{money(totals.discount)}</strong><small>Aplicados apenas aos produtos</small></div></div>
 <Panel title="Ranking comercial" sub="Respeita o acesso individual ou gerencial configurado no banco."><div className="table-scroll"><table><thead><tr><th>Vendedor</th><th>Pedidos</th><th>Produtos brutos</th><th>Descontos</th><th>Venda líquida</th></tr></thead><tbody>{rows.map(r=><tr key={r.seller_id}><td><div className="table-ident"><div className="table-avatar"><BarChart3 size={16}/></div><strong>{r.seller_name}</strong></div></td><td>{r.order_count}</td><td>{money(r.products_gross)}</td><td>{money(r.products_discount)}</td><td><strong className="green-text">{money(r.products_net)}</strong></td></tr>)}</tbody></table></div>{!busy&&!rows.length&&<Empty title="Ainda não há vendas para este relatório" description="Os pedidos confirmados aparecerão automaticamente."/>}</Panel></>;
}
