import {useEffect,useState} from 'react';
import {createClient, type SupabaseClient, type User} from '@supabase/supabase-js';
import Workspace from './Workspace';
import './secure.css';

export type Membership={id:string;tenant_id:string;company_id:string|null;branch_id:string|null;role:string;active:boolean};
export type Company={id:string;tenant_id:string;trade_name:string;legal_name:string;cnpj:string|null;active:boolean};
export type Branch={id:string;company_id:string;name:string;active:boolean};
type AuthMode='login'|'forgot'|'change';

const url=import.meta.env.VITE_SUPABASE_URL as string|undefined;
const publishableKey=import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY as string|undefined;
export const db:SupabaseClient|null=url&&publishableKey?createClient(url,publishableKey,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}}):null;

function friendlyError(code?:string,status?:number){
 if(code==='invalid_credentials')return 'E-mail ou senha não conferem. Se você aceitou o convite mas ainda não definiu sua senha, utilize “Esqueci minha senha”.';
 if(code==='email_not_confirmed')return 'Este e-mail ainda precisa ser confirmado. Confira sua caixa de entrada.';
 if(code==='over_email_send_rate_limit'||code==='over_request_rate_limit'||status===429)return 'Muitas tentativas em pouco tempo. Aguarde antes de solicitar outro e-mail.';
 if(code==='weak_password')return 'Escolha uma senha mais forte e diferente da anterior.';
 return `Não foi possível concluir a solicitação${code?' ('+code+')':''}. Verifique a conexão e tente novamente.`;
}

export default function AccessGate(){
 const [user,setUser]=useState<User|null>(null);
 const [initializing,setInitializing]=useState(true);
 const [email,setEmail]=useState('');
 const [password,setPassword]=useState('');
 const [passwordAgain,setPasswordAgain]=useState('');
 const [mode,setMode]=useState<AuthMode>('login');
 const [recoverySession,setRecoverySession]=useState(false);
 const [error,setError]=useState('');
 const [notice,setNotice]=useState('');
 const [busy,setBusy]=useState(false);
 const [memberships,setMemberships]=useState<Membership[]>([]);
 const [companies,setCompanies]=useState<Company[]>([]);
 const [branches,setBranches]=useState<Branch[]>([]);
 const [loaded,setLoaded]=useState(false);


 useEffect(()=>{
  if(!db){setInitializing(false);return;}
  let active=true;
  const {data:{subscription}}=db.auth.onAuthStateChange((event,session)=>{
   if(!active)return;
   if(event==='PASSWORD_RECOVERY'){
    setMode('change');setRecoverySession(true);
    setError('');setNotice('Link de recuperação validado. Crie sua nova senha.');
   }
   if(event==='SIGNED_OUT'){
    setRecoverySession(false);setMode('login');
   }
   setUser(session?.user??null);
   if(event==='INITIAL_SESSION'||event==='SIGNED_IN'||event==='SIGNED_OUT'||event==='PASSWORD_RECOVERY'){
    setLoaded(false);
   }
  });
  db.auth.getUser().then(({data})=>{if(active){setUser(data.user??null);if(data.user&&new URLSearchParams(window.location.search).get('sgi_recovery')==='1'){setRecoverySession(true);setMode('change');setNotice('Sessão de recuperação validada. Defina uma nova senha.');}setInitializing(false);}})
    .catch(()=>{if(active)setInitializing(false)});
  return()=>{active=false;subscription.unsubscribe()};
 },[]);

 useEffect(()=>{
  if(!db||!user||recoverySession){setLoaded(false);setMemberships([]);return;}
  let active=true;
  const load=async()=>{
   const [m,c,b]=await Promise.all([
    db!.from('user_memberships').select('id,tenant_id,company_id,branch_id,role,active').eq('active',true),
    db!.from('companies').select('id,tenant_id,trade_name,legal_name,cnpj,active').eq('active',true),
    db!.from('branches').select('id,company_id,name,active').eq('active',true)
   ]);
   if(active){
    if(m.error||c.error||b.error)setError(m.error?.message||c.error?.message||b.error?.message||'Erro ao consultar permissões');
    setMemberships((m.data??[]) as Membership[]);
    setCompanies((c.data??[]) as Company[]);
    setBranches((b.data??[]) as Branch[]);
    setLoaded(true);
   }
  };
  void load();return()=>{active=false};
 },[user?.id,recoverySession]);

 async function signIn(e:React.FormEvent){
  e.preventDefault();if(!db)return;
  setBusy(true);setError('');setNotice('');
  try{
   const {error:err}=await db.auth.signInWithPassword({email:email.trim().toLowerCase(),password});
   if(err){setError(friendlyError(err.code,err.status));}
   else setPassword('');
  }catch{setError('Não foi possível conectar ao servidor de autenticação. Confira sua conexão.');}
  finally{setBusy(false)}
 }
 async function requestReset(e:React.FormEvent){
  e.preventDefault();if(!db)return;
  setBusy(true);setError('');setNotice('');
  try{
   const {error:err}=await db.auth.resetPasswordForEmail(email.trim().toLowerCase(),{
    redirectTo:`${window.location.origin}/?sgi_recovery=1`
   });
   if(err){setError(friendlyError(err.code,err.status));}
   else setNotice('Solicitação enviada. Se o e-mail estiver cadastrado e o envio disponível, você receberá um link para definir uma nova senha. Verifique também o spam.');
  }catch{setError('Falha de conexão ao solicitar a recuperação da senha.');}
  finally{setBusy(false)}
 }
 async function changePassword(e:React.FormEvent){
  e.preventDefault();if(!db||!user||!recoverySession)return;
  if(password.length<8){setError('Use uma senha com pelo menos 8 caracteres.');return;}
  if(password!==passwordAgain){setError('As duas senhas não coincidem.');return;}
  setBusy(true);setError('');
  try{
   const {error:err}=await db.auth.updateUser({password});
   if(err){setError(friendlyError(err.code,err.status));return;}
   setPassword('');setPasswordAgain('');setRecoverySession(false);
   setMode('login');setNotice('Senha atualizada! Entre usando sua nova senha.');
   window.history.replaceState({},'',window.location.pathname);
   await db.auth.signOut();
  }catch{setError('Não foi possível alterar a senha. Solicite um novo link e tente novamente.');}
  finally{setBusy(false)}
 }

 if(!db)return <div className="sgi-auth-page"><div className="sgi-login"><h1>Móveis & Cia SGI</h1><p>Ambiente não configurado. Copie <code>.env.example</code> para <code>.env.local</code>, informe a URL e a chave publicável do Supabase e reinicie o Vite.</p></div></div>;
 if(initializing)return <div className="sgi-auth-page"><div className="sgi-login"><h2>Verificando sessão...</h2></div></div>;
 if(recoverySession&&user)return <div className="sgi-auth-page"><form className="sgi-login" onSubmit={changePassword}>
  <img src="/brand.jpg" alt="Móveis & Cia Gold" className="sgi-login-logo"/>
  <h1>Definir nova senha</h1><p>Confirme uma senha exclusiva para o seu acesso.</p>
  <label>Nova senha<input type="password" autoComplete="new-password" minLength={8} required value={password} onChange={e=>setPassword(e.target.value)}/></label>
  <label>Repetir nova senha<input type="password" autoComplete="new-password" minLength={8} required value={passwordAgain} onChange={e=>setPasswordAgain(e.target.value)}/></label>
  {error&&<div className="sgi-alert" role="alert">{error}</div>}
  {notice&&<div className="sgi-auth-notice" role="status">{notice}</div>}
  <button className="sgi-button" type="submit" disabled={busy}>{busy?'Atualizando...':'Salvar nova senha'}</button>
  <small>Não compartilhe a senha de acesso.</small>
 </form></div>;
 if(!user)return <div className="sgi-auth-page"><form className="sgi-login" onSubmit={mode==='forgot'?requestReset:signIn}>
  <img src="/brand.jpg" alt="Móveis & Cia Gold" className="sgi-login-logo"/>
  <h1>{mode==='forgot'?'Recuperar acesso':'Móveis & Cia SGI'}</h1>
  <p>{mode==='forgot'?'Enviaremos um link para redefinir sua senha.':'Sistema de Gestão Integrada · Acesso restrito'}</p>
  <label>E-mail<input type="email" required autoComplete="username" value={email} onChange={e=>setEmail(e.target.value)} placeholder="seuemail@empresa.com.br"/></label>
  {mode!=='forgot'&&<label>Senha<input type="password" required autoComplete="current-password" value={password} onChange={e=>setPassword(e.target.value)}/></label>}
  {error&&<div className="sgi-alert" role="alert">{error}</div>}
  {notice&&<div className="sgi-auth-notice" role="status">{notice}</div>}
  <button className="sgi-button" disabled={busy} type="submit">{busy?'Processando...':mode==='forgot'?'Enviar link de recuperação':'Entrar no sistema'}</button>
  {mode==='forgot'?<button className="sgi-auth-link" type="button" onClick={()=>{setMode('login');setError('')}}>Voltar ao login</button>:
   <button className="sgi-auth-link" type="button" onClick={()=>{setMode('forgot');setError('');setNotice('');setPassword('')}}>Esqueci minha senha</button>}
  <small>Cadastro de usuários somente pela administração. Nunca compartilhe sua senha.</small>
 </form></div>;
 if(!loaded)return <div className="sgi-auth-page"><div className="sgi-login"><h2>Carregando permissões...</h2></div></div>;
 if(error)return <div className="sgi-auth-page"><div className="sgi-login"><h2>Não foi possível verificar as permissões</h2><p>{error}</p><button className="sgi-button" onClick={()=>window.location.reload()}>Tentar novamente</button><button className="sgi-auth-link" onClick={()=>void db.auth.signOut()}>Sair</button></div></div>;
 if(!memberships.length)return <div className="sgi-auth-page"><div className="sgi-login"><h2>Conta aguardando autorização</h2><p>O login foi realizado, mas não existe vínculo ativo com uma empresa ou loja.</p><p><strong>{user.email}</strong></p><button className="sgi-button" onClick={()=>void db.auth.signOut()}>Sair</button></div></div>;
 return <Workspace db={db} user={user} memberships={memberships} companies={companies} branches={branches} onSignOut={()=>void db.auth.signOut()}/>;
}
