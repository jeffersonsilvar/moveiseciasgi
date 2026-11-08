# Móveis & Cia SGI — Commerce OS

Sistema integrado de vendas, financeiro, fabricação e logística. Primeira versão real conectada ao Supabase, com design repensado a partir do conceito aprovado.

**Não confunda ambiente tecnicamente conectado com homologação de produção.** Leia `docs/STATUS.md` antes de usar dados reais.

## Instalação (Windows / VS Code)

```powershell
npm install
# Este pacote já inclui .env.local com SOMENTE a chave publicável do projeto Supabase.
# Se precisar recriar o arquivo, copie .env.example e preencha a chave PUBLICÁVEL.
npm run build
npm run dev
```

O servidor exibirá `http://localhost:5173`. A conta administrativa Master já deve estar cadastrada pelo Supabase Auth.

Repositório de destino: `jeffersonsilvar/moveiseciasgi`. **O frontend deste ZIP ainda não foi enviado ao GitHub.**
Supabase: `wpwnmdpgplvxnnkldtrg`.

### Regras implementadas
- Pedido é uma página completa, cadastro/edição de cliente é modal.
- Vendas por vendedor: produtos líquidos = bruto - desconto, frete/montagem fora.
- Vários pagamentos no mesmo pedido e saldo com vencimento.
- Rascunhos editáveis, exclusão auditada (cancelamento lógico).
- Financeiro e fabricação bloqueiam agendamento e carga.
- Agenda por CEP/endereço, bairro/cidade e vagas transacionais (sem simulação de disponibilidade).
- Multiempresa e perfis verificados no banco de dados.

### Migrações
As migrações `sgi_01` a `sgi_14` foram aplicadas ao banco Supabase remoto nesta conversa. As migrações complementares ficam registradas no histórico do Supabase. Antes de outros ambientes, extraia e versione o baseline via Supabase CLI.

### Importante
Não utilizar segredos de servidor nem usar `service_role` no navegador. As chaves no frontend devem ser **publicáveis**. O `.env.local` é ignorado pelo Git.

## Ajuste v0.9.2 — Menu lateral

A identidade visual utiliza o símbolo extraído da arte oficial Móveis & Cia (em `public/brand-symbol.png`), com cabeçalho e menus responsivos que não deixam textos ultrapassarem a sidebar. O conteúdo funcional segue a v0.9.1.

## Atualização v0.9.3 — 08/11/2026

- Melhoria na inicialização das permissões para evitar a tela de espera repetida ao retornar à aba.
- Correção do fluxo de edição e confirmação de rascunhos (`private.sgi_update_draft`, já corrigido no Supabase).
- Novo layout de impressão comercial A4 (botão **Imprimir pedido** na jornada).
- Máscaras de CPF, CNPJ, telefone e CEP; normalização visual de nomes e endereços.
- Guia de continuidade: `docs/HANDOFF_PROXIMA_CONVERSA.md`.

Os arquivos da versão não contêm segredos privados. Não inclua `.env.local` no GitHub. O sistema continua em **homologação**, ainda não aprovado para dados reais.


## Atualização v0.9.5 — fila de expedição

- Inclui painel **Pedidos sem agendamento**, mesmo que ainda existam bloqueios de financeiro, fabricação, endereço, região ou capacidade.
- A liberação de fabricação **não agenda automaticamente**. Somente a reserva de vaga gera uma entrega na agenda.
- O backend compara cidade/bairro de forma padronizada, inclusive nomes com e sem acento.
- A expedição autorizada pode reservar uma data respeitando a mesma validação de pagamento, produção e capacidade.
- Confira `docs/EXPEDICAO_JORNADA.md` para testes e restrições.

**Nota:** confirme `npm run build` e os fluxos de permissões antes de usar dados reais.
