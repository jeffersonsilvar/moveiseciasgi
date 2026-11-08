# Móveis & Cia SGI

Sistema de Gestão Integrada para clientes, vendas, contas a receber e expedição das empresas do grupo Móveis & Cia.

## Stack
React + TypeScript + Vite + Supabase (Auth/PostgreSQL/RLS).

## Situação
Fundação do banco aplicada no projeto Supabase `wpwnmdpgplvxnnkldtrg` com as tabelas de empresas, usuários, clientes, endereços, produtos, pedidos, pagamentos e contas a receber. As migrações foram registradas no histórico remoto do Supabase.

O frontend v0.6 está sendo testado localmente e precisa ser enviado ao GitHub após validação.

## Segurança
Nunca comitar `.env.local`, tokens secretos, `service_role`, senhas ou dados reais de clientes. Login autenticado não implica acesso: permissões dependem de `user_memberships` e RLS.

**Atenção**: enquanto este repositório for público, não incluir dados sensíveis da empresa.
