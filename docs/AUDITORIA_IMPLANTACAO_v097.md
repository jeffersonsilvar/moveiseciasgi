# Móveis & Cia SGI — Auditoria de implantação, v0.9.7

Data de referência: 08/11/2026. Projeto: Supabase `wpwnmdpgplvxnnkldtrg`; GitHub `jeffersonsilvar/moveiseciasgi`.

## O que foi implementado, mas ainda exige homologação

- Supabase Auth; perfis `tenant_admin`, `company_admin`, `manager`, `seller`, `finance`, `production`, `shipping`, `viewer`, vínculo por empresa/unidade; RLS e RPCs com proteção no banco.
- Clientes, múltiplos endereços, busca e CEP; produtos e SKU; emissão de pedido, rascunho, confirmação, impressão, vendedor e descontos apenas sobre os produtos.
- Pagamentos combinados, baixa posterior e contas a receber; o status `paid` registra uma declaração de recebimento, **não comprova conciliação bancária**.
- Fabricação por item, reversão auditada, agenda por região, reserva de capacidade transacional, frota e romaneios, fila operacional de pendências.
- Administração de vínculos de usuários: consulta, alteração de papel dentro do mesmo escopo, nome, ativação, inativação e remoção de vínculo **sem movimentos**. A identidade `auth.users` não é apagada por esta rotina.
- Relatório comercial mensal por vendedor: base `produtos - descontos`, exclui frete/montagem, competência baseada na confirmação. Pedidos legados sem `confirmed_at` usam `created_at` como aproximação **sinalizada no relatório**.
- Motor geográfico: API BrasilAPI CEP V2 via Supabase Edge Function com JWT, cache de CEP, cálculo Haversine em km em linha reta para sugerir melhor aproveitamento das datas existentes. Não é roteirização rodoviária nem cria capacidade fictícia.
- Login conceitual com autenticação Supabase real, sem senha em página demonstrativa.

## Onde a implantação ainda NÃO está pronta para vendas reais (P0)

1. **Hospedagem comercial:** projeto Vercel deve estar em Pro ou superior. Hobby é não comercial conforme termos da Vercel. O projeto ainda não está publicado via Vercel nesta entrega.
2. **Backup/recuperação:** Supabase Free não oferece backups automáticos. Atualizar para Pro ou implantar exportação auditada, restauração testada, retenção e cópia externa antes de dados reais.
3. **Homologação de perfis:** testar autenticação por perfil com duas empresas, duas lojas e usuários distintos; confirmar isolamento de clientes, pedidos, comissões, agendas e usuários; testar saída/revogação de sessão.
4. **Financeiro:** comprovar integralidade, conciliação de Pix e cartão, cancelamento, estornos, devoluções, inadimplência, alterações de pedidos confirmados, trilha de auditoria e fechamento de caixa. A lógica atual de pagamento é **registro manual**, sem aprovação do banco/adquirente.
5. **Fiscal e LGPD:** documentos fiscais, políticas de consentimento, base legal, retenção, controle de dados pessoais, registro de acesso, exportação e exclusão regulamentada.
6. **Vendas concorrentes:** testes ponta a ponta de gravação de pedido, duplicidade, reenvio de pagamentos, quedas de conexão, concorrência por última vaga e romaneio em operação real.
7. **Política de preço:** desconto promocional de 20% à vista apenas para sofás e poltronas; demais categorias somente parcelamento de até 10 vezes, salvo autorização específica. Hoje falta validação automática por categoria/forma de pagamento e política de campanha.
8. **Segurança:** ativar proteção de senhas vazadas no Supabase, rever MFA, CORS/redirecionamentos, rate limiting, RLS/funções privilegiadas, chave de serviço e monitoramento de falhas.
9. **CI/build:** este pacote foi submetido a verificação sintática TSX, mas **build completo npm/Vite deve ser testado em máquina com acesso ao registro npm**. Versionar `package-lock.json` gerado por `npm install` após passar o build.

## Evoluções relevantes (P1/P2)

- Produção: estoque real, disponibilidade por quantidade, reservas de estoque, entrega parcial, rastreio de encomendas por fornecedor, assistência técnica, devolução/retorno e remarcação após ocorrência.
- Logística: geocodificação exata quando apropriado, provedor de roteamento rodoviário com contrato e limites; restrições de volume e peso; janelas de cliente, feriados, zonas contíguas e capacidade por veículo; comprovante de entrega assinado com política de retenção.
- Comissões: percentuais por vendedor/produto, estornos no ciclo seguinte, fechamento e aprovação mensal, relatório assinado, pagamento de comissão e reconciliação de alterações.
- SaaS: criação automatizada de tenant, isolamento e auditoria verificáveis, quotas, preços e assinaturas, faturamento SaaS, suporte, observabilidade, plano de recuperação e SLA.

## Plano de homologação amanhã (apenas dados fictícios)

1. `npm install`, `npm run build`, `npm run dev` e console sem erros.
2. Validar login, recuperação, permissão Master e vínculo inativo; teste com vendedor e financeiro distintos.
3. Criar cliente fictício, endereço e produto; salvar e editar rascunho; confirmar pedido e imprimir.
4. Registrar Pix+cartão+saldo pendente fictícios e receber saldo; verificar relatório financeiro.
5. Confirmar fabricação, desfazer liberação com motivo, configurar região e capacidade, testar agendamento/cancelamento e romaneio.
6. Comparar relatório de vendedores em meses diferentes, verificar zero no novo mês e histórico do anterior.
7. Geocodificar apenas CEP fictício/de teste, comparar sugestões e confirmar etiqueta "distância em linha reta"; sem dados de deslocamento, a agenda por região continua sendo a fonte de datas reserváveis.
8. Habilitar backups e Pro antes de permitir operação com clientes reais; somente depois liberar o domínio de produção.
