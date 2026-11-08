export const money=(value:number|string|null|undefined)=>Number(value??0).toLocaleString('pt-BR',{style:'currency',currency:'BRL'});
export const digits=(value:string)=>String(value??'').replace(/\D/g,'');
export const amount=(value:string|number)=>Number(value)||0;
export const dateBR=(value:string|null|undefined)=>value?new Date(`${value.slice(0,10)}T12:00:00`).toLocaleDateString('pt-BR'): '—';
export const dateTimeBR=(value:string|null|undefined)=>value?new Date(value).toLocaleString('pt-BR',{timeZone:'America/Recife'}):'—';
export const today=()=>{const f=new Intl.DateTimeFormat('en-CA',{timeZone:'America/Recife',year:'numeric',month:'2-digit',day:'2-digit'});return f.format(new Date())};
export const escapeHtml=(value:unknown)=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]??c));
export const errMsg=(error:unknown)=>error instanceof Error?error.message:String(error??'Erro desconhecido');
export const sampleCurrency=(v:string)=>Number.isFinite(Number(v))&&Number(v)>=0;
export const clamp=(n:number,min:number,max:number)=>Math.max(min,Math.min(n,max));
export const statusLabel:Record<string,string>={draft:'Rascunho',confirmed:'Confirmado',cancelled:'Cancelado',closed:'Encerrado',unpaid:'Não pago',partial:'Parcial',paid:'Quitado',refunded:'Estornado',ready:'Disponível',manufacturing:'Em fabricação',ordered:'Encomendado',blocked:'Bloqueado',scheduled:'Agendada',loaded:'Carregada',in_route:'Em rota',delivered:'Entregue',failed:'Ocorrência',pickup:'Retirada',delivery:'Domicílio',assembly:'Montagem',dispatched:'Em rota',returned:'Retornado'};
export function validateCpfCnpj(doc:string){const s=digits(doc);if(![11,14].includes(s.length)||/^(\d)\1+$/.test(s))return false;if(s.length===11){let a=0;for(let i=0;i<9;i++)a+=+s[i]*(10-i);let x=(a*10)%11;if(x===10)x=0;if(x!==+s[9])return false;a=0;for(let i=0;i<10;i++)a+=+s[i]*(11-i);x=(a*10)%11;if(x===10)x=0;return x===+s[10]};let size=12;for(let k=0;k<2;k++){let sum=0;let weight=size-7;for(let i=size-1;i>=0;i--){sum+=Number(s[i])*weight--;if(weight<2)weight=9}const d=sum%11<2?0:11-sum%11;if(d!==Number(s[size]))return false;size++}return true}
