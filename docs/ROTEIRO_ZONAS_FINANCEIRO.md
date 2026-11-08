# SGI Commerce OS v0.9.6 — Zonas, fabricação e financeiro

## Zona logística
- Uma zona contém múltiplos pares cidade/bairro, adicionados em lote.
- Renomear, desvincular bairro, desativar e reativar via RPC, com permissão de tenant_admin e audit_logs.
- Não desvincular bairro de entregas ativas nem desativar zona com reservas futuras.
- O mesmo bairro normalizado não pode ser incluído em duas zonas ativas no mesmo grupo.
- O sistema encontra bairros nos pedidos confirmados para sugerir cadastro; **não presume proximidade** entre bairros.
- Proximidade automática é uma evolução futura dependente de coordenadas, roteamento, custo e validação da equipe.
- Nenhum agendamento é confirmado sem vaga real existente no Supabase.

## Reversão de fabricação
- Operação com justificativa obrigatória para perfis autorizados.
- Se houver agendamento no status `scheduled`, a reserva é cancelada, o contador de vagas é reduzido e o pedido retorna à fila, bloqueado pela fabricação.
- Se `loaded`, `in_route`, `delivered` ou `failed`, bloqueia reversão até correção logística apropriada.
- Após correção, é possível liberar novamente e agendar em uma nova data sem apagar histórico.

## Financeiro
- **Todas** as vendas comerciais confirmadas são exibidas, inclusive pagamentos totais no ato (sem receivable aberto).
- Filtros: Todas, Quitadas, Parcialmente pagas, Sem pagamento e Vencidas.
- Totais da tela são calculados apenas sobre a página visível (não consolidado de toda empresa).
- Status Quitado = lançamento no SGI, não confirmação bancária externa.
- Relatório por vendedor permanece baseado no valor líquido dos produtos, excluindo frete/montagem.

## Homologação
1. Cadastrar zona 'Zona Sul' com Boa Viagem, Pina, Imbiribeira numa operação.
2. Editar, remover bairro e arquivar zona sem entregas pendentes.
3. Criar pedido fictício confirmado, pago, com item fabricação; liberar item.
4. Agendar data com capacidade de teste. Desfazer liberação com motivo. Confirmar cancelamento da reserva, devolução da vaga e bloqueio.
5. Liberar novamente, reagendar e confirmar histórico.
6. Cadastrar pedido quitado e pedido parcialmente pago; verificar ambos no Financeiro.
7. Testar com usuário sem permissão: não pode editar zona nem alterar fabricação.
8. Testar carga/romaneio: reversão deve falhar depois de carregar a mercadoria.

**As migrações 18 e 19 já foram aplicadas ao projeto remoto Supabase.** Não execute os scripts novamente manualmente no projeto conectado; mantenha-os no versionamento como histórico lógico.
