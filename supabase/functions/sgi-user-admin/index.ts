import { createClient } from "npm:@supabase/supabase-js@2.57.0";

const origin = "https://sgi.moveisecia.tech";
const cors = {
  "Access-Control-Allow-Origin": origin,
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Cache-Control": "no-store",
  "Vary": "Origin",
};
const reply = (status: number, message: string, ok = false) =>
  new Response(JSON.stringify({ ok, message }), {
    status, headers: { ...cors, "Content-Type": "application/json" },
  });
const uuid = (v: unknown): v is string => typeof v === "string" &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
const strong = (v: unknown): v is string => typeof v === "string" &&
  v.length >= 12 && new TextEncoder().encode(v).length <= 72 &&
  /[a-z]/.test(v) && /[A-Z]/.test(v) && /[0-9]/.test(v) && /[^A-Za-z0-9\s]/.test(v);
const roles = ["company_admin", "manager", "seller", "cashier", "shipping", "finance", "production", "viewer"];
const opts = { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } };

Deno.serve(async (req: Request) => {
  if (req.headers.get("origin") && req.headers.get("origin") !== origin)
    return reply(403, "Origem não autorizada.");
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return reply(405, "Método não permitido.");
  const token = req.headers.get("authorization")?.match(/^Bearer ([^\s]+)$/i)?.[1];
  if (!token) return reply(401, "Sessão necessária.");
  try {
    const url = Deno.env.get("SUPABASE_URL");
    const anon = Deno.env.get("SUPABASE_ANON_KEY");
    const secret = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !anon || !secret) return reply(503, "Serviço administrativo indisponível.");
    const caller = createClient(url, anon, { ...opts, global: { headers: { Authorization: "Bearer " + token } } });
    const { data: identity, error: authError } = await caller.auth.getUser(token);
    if (authError || !identity.user) return reply(401, "Sessão inválida. Entre novamente.");
    const actor = identity.user.id;
    const raw = await req.text();
    if (raw.length > 8192) return reply(413, "Solicitação muito extensa.");
    let b;
    try { b = JSON.parse(raw); } catch { return reply(400, "Solicitação inválida."); }
    if (!b || typeof b !== "object" || !uuid(b.tenant) || !["create", "reset"].includes(b.action))
      return reply(400, "Solicitação inválida.");
    // Existing RPC checks live tenant, profile and Master membership under the caller JWT.
    const { error: accessError } = await caller.rpc("sgi_admin_list_users", { p_tenant: b.tenant });
    if (accessError) return reply(403, "Acesso exclusivo ao Master deste grupo.");
    if (!strong(b.password)) return reply(400, "Use 12 ou mais caracteres, maiúscula, minúscula, número e símbolo (até 72 bytes).");
    const admin = createClient(url, secret, opts);
    const audit = async (action: string, target: string, company: string | null = null) => {
      const { error } = await admin.from("audit_logs").insert({
        tenant_id: b.tenant, company_id: company, actor_id: actor, action,
        entity_type: "profile", entity_id: target, changes: { method: "admin_sgi" },
      });
      return !error;
    };
    if (b.action === "create") {
      const email = typeof b.email === "string" ? b.email.trim().toLowerCase() : "";
      const name = typeof b.name === "string" ? b.name.trim() : "";
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254 ||
          name.length < 2 || name.length > 120 || !roles.includes(b.role) ||
          !uuid(b.company) || (b.branch !== null && !uuid(b.branch)) || b.confirmed !== true)
        return reply(400, "Confira nome, e-mail verificado, perfil, empresa e loja.");
      const { data: company, error: ce } = await caller.from("companies").select("id").eq("id", b.company)
        .eq("tenant_id", b.tenant).eq("active", true).maybeSingle();
      if (ce || !company) return reply(400, "Empresa inválida ou inativa.");
      if (b.branch !== null) {
        const { data: branch, error: be } = await caller.from("branches").select("id").eq("id", b.branch)
          .eq("company_id", b.company).eq("active", true).maybeSingle();
        if (be || !branch) return reply(400, "Loja inválida ou inativa.");
      }
      const { data, error } = await admin.auth.admin.createUser({
        email, password: b.password, email_confirm: true, user_metadata: { full_name: name },
        app_metadata: { sgi_managed_tenant: b.tenant },
      });
      if (error || !data.user) {
        if (["email_exists", "user_already_exists"].includes(error?.code ?? ""))
          return reply(409, "Conta já existente. Use Vincular conta existente; não alteramos a senha.");
        if (error?.code === "weak_password") return reply(400, "Senha recusada pela política do Supabase.");
        return reply(400, "Não foi possível criar a conta. Verifique o e-mail e a política de senha; se já existir, use o vínculo.");
      }
      // The auth trigger creates the named profile. The existing RPC assigns and audits the grant
      // using the caller JWT, rechecking authorization at the time of mutation.
      const grant = await caller.rpc("sgi_assign_user", {
        p_tenant: b.tenant, p_email: email, p_company: b.company, p_branch: b.branch, p_role: b.role,
      });
      if (grant.error || !grant.data) {
        // Do not delete after an ambiguous RPC failure: the grant might already be committed.
        // A newly created identity without a membership cannot use SGI.
        await audit("user.creation_link_pending", data.user.id, b.company);
        return reply(409, "Conta criada, mas o vínculo não foi confirmado. Atualize a lista e, se necessário, use Vincular conta existente com o mesmo e-mail.");
      }
      return reply(200, "Usuário criado e perfil atribuído com auditoria.", true);
    }
    // Password resets only for non-Master identities belonging exclusively to this tenant.
    // Never change the actor's or another Master's password here.
    if (!uuid(b.user_id) || b.user_id === actor) return reply(400, "Redefinição administrativa indisponível para esta conta.");
    const { data: links, error: le } = await admin.from("user_memberships")
      .select("tenant_id,role").eq("user_id", b.user_id);
    if (le || !links?.length || links.some(x => x.tenant_id !== b.tenant || x.role === "tenant_admin"))
      return reply(403, "Conta Master, sem vínculo ou vinculada a outro grupo. Use a administração do Supabase.");
    const { data: target, error: te } = await admin.auth.admin.getUserById(b.user_id);
    if (te || target.user?.app_metadata?.sgi_managed_tenant !== b.tenant)
      return reply(403, "Esta conta não foi criada pelo SGI. Redefina sua senha pelo Supabase.");
    const { error: recheck } = await caller.rpc("sgi_admin_list_users", { p_tenant: b.tenant });
    if (recheck) return reply(403, "Acesso administrativo revogado.");
    if (!await audit("user.password_reset_requested", b.user_id))
      return reply(503, "Auditoria indisponível. Senha não alterada.");
    const { error: resetError } = await admin.auth.admin.updateUserById(b.user_id, { password: b.password });
    if (resetError) {
      await audit("user.password_reset_failed", b.user_id);
      return reply(400, "Senha não alterada. Confira a política de senha.");
    }
    const logged = await audit("user.password_reset_completed", b.user_id);
    return reply(200, logged ? "Senha redefinida. Entregue-a por canal privado." :
      "Senha redefinida; registro de conclusão indisponível, mas a solicitação foi auditada.", true);
  } catch {
    // Never log request bodies, credentials or tokens.
    return reply(503, "Não foi possível confirmar a operação. Atualize a lista antes de tentar novamente.");
  }
});
