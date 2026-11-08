# Móveis & Cia SGI — Continuidade técnica (versão 0.9.3)

Data: 08/11/2026. Projeto: `jeffersonsilvar/moveiseciasgi` (branch `main`). Supabase: projeto **Moveis e Cia SGI**, organização J Tecnologia. Implementação para homologação, **não liberada para dados reais de clientes**.

## O que já existe

- Login no Supabase Auth e autorização baseada em vínculos `user_memberships` e políticas RLS.
- Dashboard, clientes, múltiplos endereços e busca de CEP, catálogo de produtos, pedido em página completa (cliente em modal), pagamentos mistos, contas a receber, fabricação, agenda, frota, romaneios e relatórios por vendedor.
- Regra comercial: `total_pedido = produtos - desconto_produtos + frete + montagem`; **venda líquida do vendedor = produtos - desconto_produtos**.
- Bloqueio para expedição de pedidos sem liberação financeira ou com produtos ainda indisponíveis.

## Correções da v0.9.3

1. **Editar rascunho**: reparado erro SQL `column reference "j" is ambiguous` em `private.sgi_update_draft`. Migração aplicada no Supabase, e teste real executado em transação seguida por `ROLLBACK` (não houve alteração persistida). A confirmação de rascunho também passou em teste com `ROLLBACK`.
2. **Carregamento de permissões**: não reinicia o acesso em cada evento `SIGNED_IN` repetido ao retornar à aba. Só reinicializa quando muda a identidade. Depois de 8 segundos mostra aviso e opção de repetir a consulta, preservando o controle de acesso.
3. **Impressão comercial**: nova página A4 profissional, com logo, empresa/CNPJ, documento e contato do cliente, vendedor, endereço, produtos, cor, frete, montagem, desconto, recebimentos e saldo, observações e assinaturas; rascunhos identificados. Arquivo `src/lib/orderPrint.ts`.
4. **Padronização visual dos cadastros**: funções reutilizáveis `formatCpfCnpj`, `formatCep`, `formatPhone`, `titleCaseBR`. CPF/CNPJ/CEP armazenados sem pontuação onde já configurado; nomes com iniciais maiúsculas e preposições minúsculas, e-mail em minúsculas, SKU em maiúsculas. O padrão é aplicado nos formulários principais; ainda precisa ser auditado nas demais telas.
5. **Edição de rascunho**: preserva `product_id` dos itens existentes, sem perder a vinculação ao catálogo.

## Verificação realizada

- Supabase: teste transacional de atualização de rascunho = aprovado; confirmação de rascunho = aprovado. Ambos com `ROLLBACK`.
- TypeScript: análise sintática dos arquivos alterados = aprovada. Não houve compilação Vite completa neste ambiente porque o registro npm não respondeu. Rodar `npm install` e `npm run build` no Windows.
- Impressão: HTML renderizado em PDF A4 e conferido visualmente usando exemplo **fictício**; resultado de uma página.

## Pendente e necessário antes do uso operacional real

- Homologar `npm run build` e o fluxo por interface com múltiplos perfis / empresas.
- Completar testes de RLS para vendedor, financeiro, fabricação e expedição; teste de concorrência de pedidos/agendamentos.
- Revisar cadastro e permissões das três lojas; configurar backup/restore, retenção LGPD, fluxo de cancelamento/estornos, conciliação financeira e controles de disponibilidade física.
- Testar a aparência impressa nos navegadores e impressoras utilizados nas lojas, inclusive pedidos longos.
- Conectar efetivamente CI do GitHub com `package-lock.json` versionado após a primeira instalação local (`npm install`, depois `git add package-lock.json`).
- Repositório é/era público; torná-lo privado antes de incluir dados empresariais sensíveis.

## Roteiro de teste imediato

1. Entrar com conta Master (senha nunca compartilhada).
2. Abrir pedido #000001 se ainda estiver em rascunho. Clicar **Editar rascunho**; alterar um item, salvar novamente, voltar e confirmar.
3. Trocar de abas e retornar ao SGI para garantir que não apareça `Carregando permissões...` repetidamente.
4. Imprimir pedido e salvar em PDF no navegador; comparar com o modelo de exemplo, conferir assinaturas e margens.
5. Cadastrar cliente fictício usando máscara de CPF, celular e CEP; digitar nomes em minúsculas e verificar padronização no blur.
6. Testar perfil sem vínculo e perfil de loja para validar isolamento.

## Importante

A captura de tela enviada em 08/11/2026 continha dados de clientes. Não publicar esses prints no GitHub. Não versionar `.env.local`, senhas, service-role nem dados reais. O banco já tem histórico; não recriar tabelas ou reaplicar migrações que já estejam no Supabase.
