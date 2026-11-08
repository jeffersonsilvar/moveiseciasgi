import {useEffect,useState} from 'react';
import {AlertCircle,ArrowRight,MapPin,Plus,Save,Search,X} from 'lucide-react';
import type {FormEvent} from 'react';
import type {AppContext,Client,Address,Order} from '../lib/types';
import {digits,dateBR,money,validateCpfCnpj,formatCpfCnpj,formatPhone,formatCep,titleCaseBR,friendlyDatabaseError} from '../lib/utils';
import {Field,ErrorBox,Status} from './UI';
type AddressForm={id:string|null;label:string;cep:string;street:string;number:string;neighborhood:string;city:string;state:string;complement:string;reference_point:string;is_primary:boolean;active:boolean};
const blankAddress=():AddressForm=>({id:null,label:'Principal',cep:'',street:'',number:'',neighborhood:'',city:'',state:'PE',complement:'',reference_point:'',is_primary:true,active:true});
const fromAddress=(a:Address):AddressForm=>({id:a.id,label:a.label,cep:a.cep??'',street:a.street??'',number:a.number??'',neighborhood:a.neighborhood??'',city:a.city??'',state:a.state??'PE',complement:a.complement??'',reference_point:a.reference_point??'',is_primary:a.is_primary,active:a.active});
export function CustomerModal({ctx,customer,onClose,onSaved}:{ctx:AppContext;customer?:Client|null;onClose:()=>void;onSaved:(id:string)=>void}){
 const [name,setName]=useState(customer?.name??'');const [kind,setKind]=useState(customer?.kind??'person');const [document,setDocument]=useState(customer?.document??'');const [mobile,setMobile]=useState(customer?.mobile??'');const [phone,setPhone]=useState(customer?.phone??'');const [email,setEmail]=useState(customer?.email??'');const [active,setActive]=useState(customer?.active??true);
 const [addresses,setAddresses]=useState<AddressForm[]>(customer?.customer_addresses?.length?customer.customer_addresses.map(fromAddress):[blankAddress()]);
 const [focusAddress,setFocusAddress]=useState(0);const [busy,setBusy]=useState(false);const [lookingUp,setLookingUp]=useState(false);const [error,setError]=useState('');const [history,setHistory]=useState<Pick<Order,'id'|'order_number'|'commercial_status'|'grand_total'|'created_at'>[]>([]);
 useEffect(()=>{if(!customer)return;void ctx.db.from('orders').select('id,order_number,commercial_status,grand_total,created_at').eq('company_id',ctx.companyId).eq('customer_id',customer.id).order('created_at',{ascending:false}).limit(10).then(({data})=>setHistory(data??[]));},[customer?.id]);
 const addr=addresses[focusAddress]??blankAddress();
 const changeAddress=(patch:Partial<AddressForm>)=>setAddresses(old=>old.map((a,i)=>i===focusAddress?{...a,...patch}:a));
 const choosePrimary=(index:number)=>setAddresses(old=>old.map((a,i)=>({...a,is_primary:i===index,active:i===index?true:a.active})));
 const lookup=async()=>{if(digits(addr.cep).length!==8){setError('O CEP deve conter 8 dígitos.');return;}setLookingUp(true);setError('');try{const res=await fetch(`https://viacep.com.br/ws/${digits(addr.cep)}/json/`);if(!res.ok)throw new Error('Consulta indisponível');const d=await res.json();if(d.erro)throw new Error('CEP não localizado');changeAddress({street:d.logradouro??'',neighborhood:d.bairro??'',city:d.localidade??'',state:d.uf??'PE'});}catch(e){setError(e instanceof Error?e.message:'Falha na consulta ao CEP.');}finally{setLookingUp(false)}};
 const save=async(e:FormEvent)=>{e.preventDefault();if(!ctx.branchId){setError('Selecione uma loja válida.');return;}if(!validateCpfCnpj(document)&&!customer){setError('Informe um CPF ou CNPJ válido.');return;}if(digits(mobile).length<10){setError('Celular inválido.');return;}if(!name.trim()||name.trim().length<2){setError('Informe o nome ou razão social.');return;}
  setBusy(true);setError('');try{
   const all=addresses.filter(a=>a.cep.trim()||a.street.trim()||a.number.trim());
   for(const a of all){if(digits(a.cep).length!==8||!a.street.trim()||!a.number.trim()||!a.city.trim()||!a.neighborhood.trim()||a.state.length!==2||a.reference_point.length>50)throw new Error('Preencha todos os campos obrigatórios de cada endereço. Referência: até 50 caracteres.');}
   let customerId=customer?.id??'';
   if(customer){const {error:err}=await ctx.db.rpc('sgi_update_customer',{p_customer:customer.id,p_name:titleCaseBR(name),p_mobile:digits(mobile),p_phone:digits(phone),p_email:email.trim().toLowerCase(),p_active:active});if(err)throw err;}
   else {const first=all[0];const {data,error:err}=await ctx.db.rpc('create_customer',{p_company:ctx.companyId,p_branch:ctx.branchId,p_kind:kind,p_name:titleCaseBR(name),p_document:digits(document),p_mobile:digits(mobile),p_phone:digits(phone),p_email:email.trim().toLowerCase(),p_address:first?{cep:digits(first.cep),street:titleCaseBR(first.street),number:first.number,neighborhood:titleCaseBR(first.neighborhood),city:titleCaseBR(first.city),state:first.state.toUpperCase(),complement:titleCaseBR(first.complement),reference_point:titleCaseBR(first.reference_point)}:{} });if(err)throw err;customerId=String(data);}
   for(const [i,a] of all.entries()){
    if(!customer && i===0)continue;
    const {error:err}=await ctx.db.rpc('sgi_save_address',{p_customer:customerId,p_id:a.id??null,p_label:titleCaseBR(a.label),p_cep:digits(a.cep),p_street:titleCaseBR(a.street),p_number:a.number,p_neighborhood:titleCaseBR(a.neighborhood),p_city:titleCaseBR(a.city),p_state:a.state.toUpperCase(),p_complement:titleCaseBR(a.complement),p_reference:titleCaseBR(a.reference_point),p_primary:a.is_primary,p_active:a.active});if(err)throw err;
   }
   ctx.notify(customer?'Cliente atualizado com sucesso.':'Cliente cadastrado com sucesso.');onSaved(customerId);
  }catch(e){setError(friendlyDatabaseError(e));}finally{setBusy(false)}
 };
 return <div className="modal-backdrop" role="presentation" onMouseDown={e=>{if(e.target===e.currentTarget)onClose()}}><div className="modal big" role="dialog" aria-modal="true" aria-labelledby="customer-title"><div className="modal-head"><div><span className="eyebrow">PESSOAS / CADASTROS</span><h2 id="customer-title">{customer?'Editar cliente':'Cadastrar cliente'}</h2><p>Um único cadastro, vários endereços e o histórico sempre preservado.</p></div><button className="icon-control" type="button" aria-label="Fechar" onClick={onClose}><X size={22}/></button></div>
 <form onSubmit={save} className="modal-body"><div className="subheading">Informações do cliente</div><div className="form-grid cols3">
 <Field label="Tipo de pessoa"><select value={kind} disabled={!!customer} onChange={e=>setKind(e.target.value)}><option value="person">Pessoa física</option><option value="company">Pessoa jurídica</option></select></Field>
 <Field label="Nome / Razão social *"><input required value={name} onChange={e=>setName(e.target.value)} onBlur={()=>setName(v=>titleCaseBR(v))} maxLength={200}/></Field>
 <Field label="CPF / CNPJ *"><input required value={formatCpfCnpj(document)} disabled={!!customer} inputMode="numeric" onChange={e=>setDocument(digits(e.target.value))} placeholder="Somente números ou formatado" maxLength={18}/></Field>
 <Field label="Celular / WhatsApp *"><input required value={formatPhone(mobile)} inputMode="tel" onChange={e=>setMobile(digits(e.target.value))} placeholder="(81) 99999-9999"/></Field>
 <Field label="Telefone"><input value={formatPhone(phone)} inputMode="tel" onChange={e=>setPhone(digits(e.target.value))}/></Field>
 <Field label="E-mail"><input type="email" value={email} onChange={e=>setEmail(e.target.value)} onBlur={()=>setEmail(v=>v.trim().toLowerCase())}/></Field>
 </div>
 <div className="section-title-row"><div className="subheading">Endereços cadastrados</div><button className="btn secondary small" type="button" onClick={()=>{setAddresses(old=>[...old,{...blankAddress(),label:'Entrega',is_primary:false}]);setFocusAddress(addresses.length)}}><Plus size={15}/> Adicionar endereço</button></div>
 <div className="address-tabs">{addresses.map((a,i)=><button className={focusAddress===i?'selected':''} type="button" key={a.id??i} onClick={()=>setFocusAddress(i)}><MapPin size={14}/>{a.label||`Endereço ${i+1}`}{a.is_primary&&<span>Principal</span>}</button>)}</div>
 <div className="address-form"><div className="form-grid cols3">
 <Field label="Identificação"><input value={addr.label} onChange={e=>changeAddress({label:e.target.value})} onBlur={()=>changeAddress({label:titleCaseBR(addr.label)})} placeholder="Residencial, Entrega, Trabalho"/></Field>
 <Field label="CEP"><div className="with-action"><input value={formatCep(addr.cep)} inputMode="numeric" onChange={e=>changeAddress({cep:digits(e.target.value)})} placeholder="00000-000" maxLength={9}/><button type="button" onClick={lookup} disabled={lookingUp} title="Consultar CEP"><Search size={16}/></button></div></Field>
 <Field label="Rua / Logradouro"><input value={addr.street} onChange={e=>changeAddress({street:e.target.value})} onBlur={()=>changeAddress({street:titleCaseBR(addr.street)})}/></Field>
 <Field label="Número"><input value={addr.number} onChange={e=>changeAddress({number:e.target.value})}/></Field>
 <Field label="Bairro"><input value={addr.neighborhood} onChange={e=>changeAddress({neighborhood:e.target.value})} onBlur={()=>changeAddress({neighborhood:titleCaseBR(addr.neighborhood)})}/></Field>
 <Field label="Cidade"><input value={addr.city} onChange={e=>changeAddress({city:e.target.value})} onBlur={()=>changeAddress({city:titleCaseBR(addr.city)})}/></Field>
 <Field label="UF"><input value={addr.state} onChange={e=>changeAddress({state:e.target.value.toUpperCase().slice(0,2)})} maxLength={2}/></Field>
 <Field label="Complemento"><input value={addr.complement} onChange={e=>changeAddress({complement:e.target.value})} onBlur={()=>changeAddress({complement:titleCaseBR(addr.complement)})}/></Field>
 <Field label="Roteirização / ponto de referência (50 caracteres)"><input value={addr.reference_point} maxLength={50} onChange={e=>changeAddress({reference_point:e.target.value})} placeholder="Até 50 caracteres"/></Field>
 </div><div className="checkbox-bar"><label><input type="checkbox" checked={addr.is_primary} onChange={()=>choosePrimary(focusAddress)}/> Endereço principal</label><label><input type="checkbox" checked={addr.active} onChange={e=>changeAddress({active:e.target.checked})}/> Endereço ativo</label></div></div>
 {customer&&<><div className="subheading">Histórico de pedidos</div>{history.length?<div className="mini-history">{history.map(o=><div key={o.id}><span>#{o.order_number} · {dateBR(o.created_at)}</span><Status value={o.commercial_status}/><strong>{money(o.grand_total)}</strong></div>)}</div>:<div className="muted-line">Nenhum pedido encontrado para este cliente.</div>}<label className="checkbox-bar"><input type="checkbox" checked={active} onChange={e=>setActive(e.target.checked)}/> Cliente ativo (cadastros com pedidos devem permanecer no histórico)</label></>}
 {error&&<ErrorBox text={error}/>}<div className="modal-actions"><button type="button" className="btn secondary" onClick={onClose}>Cancelar</button><button type="submit" className="btn primary" disabled={busy}><Save size={17}/>{busy?'Salvando...':'Salvar cadastro'}<ArrowRight size={16}/></button></div>
 </form></div></div>;
}
