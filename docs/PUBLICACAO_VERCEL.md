# Publicação controlada do Móveis & Cia SGI na Vercel

## Situação

O repositório `jeffersonsilvar/moveiseciasgi` possui `vercel.json` com framework `vite`, build `npm run build`, saída `dist` e fallback para SPA. A aplicação ainda **não foi publicada pela Vercel** nesta versão.

**Restrição:** o plano Hobby da Vercel autoriza apenas uso pessoal não comercial. Para demonstrar e operar um sistema empresarial, use Pro ou superior. O upgrade depende da ação do titular da conta. O Supabase Free não oferece backup automático.

## Preparação

1. Rever o código na branch `main` e validar `npm install && npm run build && npm run dev`.
2. Versionar o `package-lock.json` gerado pelo `npm install` e bloquear deploy quando CI falhar.
3. Tornar o repositório privado e verificar o acesso do GitHub pela integração Vercel.
4. Ativar Vercel Pro na conta/team correta (ou Pro trial, dentro das condições da plataforma).
5. Criar o projeto `moveis-cia-sgi` com importação GitHub, raiz `/`, Framework Vite, build `npm run build`, output `dist`.
6. Configurar variáveis de ambiente `VITE_SUPABASE_URL` e `VITE_SUPABASE_PUBLISHABLE_KEY` com valores do projeto Supabase adequado para homologação. **NUNCA** incluir `service_role` ou secret key em variáveis `VITE_`.
7. Configurar Supabase Authentication → URL Configuration: Site URL do domínio final, além dos endereços HTTPS permitidos para redirecionamento de recuperação. Rever curingas de preview, preferindo domínios conhecidos.
8. Separar banco de homologação e produção antes de registrar dados pessoais. A conta Master do banco atual não deve ser reutilizada como conta de teste em produção sem política de segurança.
9. Publicar preview, homologar login e jornada de pedido, verificar logs de build/runtime, testar impressão e regras de desconto e recebimento.
10. Fazer backup e **teste de restauração**, validar a política RLS com empresas/usuários distintos, aprovar a publicação de produção e definir plano de rollback.

## Rollback

Utilizar o histórico de deployments da Vercel e a versão anterior do Git. Alterações de schema exigem migrações compatíveis com deploy anterior; rollback visual não reverte automaticamente banco. Registrar aprovação, backup e roteiro de recuperação.

## Gate de implantação comercial

- [ ] Conta Vercel em plano compatível com atividade comercial.
- [ ] Banco com política de backup/restauração testada.
- [ ] Build e testes automáticos verdes.
- [ ] Testes de isolamento entre empresas e perfis.
- [ ] Comissões mensais e ajustes retroativos homologados.
- [ ] Conciliação de recebimentos, estornos e regras de descontos homologadas.
- [ ] Política LGPD e operação de suporte/monitoramento aprovadas.

Referências: https://vercel.com/legal/terms , https://supabase.com/docs/guides/platform/backups .