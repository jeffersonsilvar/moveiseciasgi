# Controle de acesso

- Autenticação: Supabase Auth (email/senha).
- Autorização: `profiles` + `user_memberships` + papéis e políticas RLS.
- `tenant_admin`: acesso a empresas do grupo autorizado.
- `company_admin` / `manager`: gestão dentro de seus vínculos.
- `seller`: pedidos e clientes apenas em lojas autorizadas.
- `finance`: consulta de pedidos/recebíveis autorizados.
- `shipping` / `production`: operações especializadas (em evolução).

Funções de gravação transacional: `public.create_customer` e `public.create_order`. Implementações privilegiadas em schema `private`, não exposto pela API.

Antes da produção: testar cada perfil com pelo menos dois usuários e empresas distintas; revisar Backups/Recovery, LGPD, aprovação financeira e fluxos de entrega.
