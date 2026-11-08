# SGI Commerce OS · Implementação real

Ambiente: Supabase Móveis e Cia SGI (projeto `wpwnmdpgplvxnnkldtrg`) + React/TypeScript/Vite.

## Fluxos

- Login e recuperação via Supabase Auth
- Isolamento por grupo, empresa e loja (RLS)
- Clientes com múltiplos endereços, CEP, histórico e edição
- Catálogo por SKU/descrição
- Pedido em página completa: rascunho, edição, confirmação, impressão
- Produtos, cores, quantidades, preços, descontos, frete e montagem
- Pagamentos mistos e saldo a receber, baixa posterior com auditoria
- Liberação financeira excepcional, com motivo
- Produção/encomenda por item, previsão e liberação
- Agenda inteligente por bairro e cidade (requer configuração prévia)
- Capacidade por data/região e reserva transacional
- Gestão de frota e motorista, romaneio, saída, baixa e fechamento
- Relatório de vendas por vendedor (produtos líquidos sem serviços)

## Limitações antes de produção

**Este pacote não recebeu homologação integral com usuários reais e NÃO deve ser promovido a produção com dados pessoais sem a bateria de testes de segurança, auditoria, backup/restauração, concorrência, impressão e falhas de rede.**

- Pagamento é declarado manualmente; ainda não há conciliação com adquirente/banco.
- Controle fiscal (NF-e/NFC-e) não integrado: impressão é comprovante comercial, não nota fiscal.
- Roteirização funciona por região/bairro configurados, ainda não faz otimização por estrada em tempo real.
- Liberações financeiras excepcionais dependem da governança de autorizações da empresa.
- Cadastro de usuários exige convite prévio pelo Supabase Authentication.
- Não está implementada prova de entrega fotográfica, portal de motorista ou offline sync.
- Testes de concorrência, backup, LGPD e SLA precisam de execução operacional.
- Não há monitoramento ativo de indisponibilidade, rate limiting específico por usuário no app ou rotina de disaster recovery validada.

## Segurança antes do go-live

1. GitHub **Private** antes de qualquer informação confidencial.
2. Nunca enviar `.env.local`, senhas, `service_role` ou chave secreta ao repositório.
3. Supabase Auth: impor MFA para perfis de diretoria, confirmação de email, restringir signup público.
4. Conferir todas as policies RLS e privilégios por role. Testar usuários de duas empresas.
5. Testar criação de pedido simultânea, mudança de descontos, alterações de saldo e dupla reserva de entrega.
6. Configurar backups e exercitar restauração em ambiente separado.
7. Publicar com HTTPS, política de privacidade, termos de uso e retenção de dados.
8. Executar `npm audit`, testes end-to-end e testes de carga após `npm install` no ambiente com acesso ao npm.
9. Fazer piloto com usuários fictícios e só então começar a migração real.
