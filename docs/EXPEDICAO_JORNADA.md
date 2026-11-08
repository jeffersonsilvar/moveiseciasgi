# Jornada da expedição — SGI Commerce OS v0.9.5

## Estados independentes

1. Pedido em rascunho: fora da fila da expedição.
2. Pedido confirmado: aparece na fila de pedidos sem data quando exige entrega ou montagem externa.
3. Financeiro pendente: fila aponta bloqueio financeiro.
4. Fabricação pendente: fila aponta bloqueio de produção.
5. Financeiro e produção liberados: fila mostra **sem região**, **sem data com vaga** ou **pronto para agendar**, conforme configuração.
6. Reserva efetiva: função transacional `sgi_book_delivery` cria a entrada em `delivery_bookings`, que passa a aparecer na **Agenda de entregas**.
7. Romaneio: utiliza apenas entregas agendadas e liberadas.

## Regras de segurança

- `public.sgi_dispatch_queue` valida o usuário em cada unidade e retorna somente pedidos da empresa permitida.
- Implementação privilegiada no schema `private`, não exposto.
- A reserva não pode ser criada para venda não confirmada, sem quitação/autorizações, item indisponível ou capacidade esgotada.
- Regiões usam uma chave normalizada para comparação; endereço do cliente não é modificado.
- A fila não é o romaneio e não cria reserva fictícia.

## Homologação

- Testar pedido pago com fabricação liberada e sem data: deve aparecer na fila.
- Testar região ainda não mapeada: informar bloqueio; configurar cidade e bairro.
- Testar região configurada sem datas: informar capacidade pendente.
- Testar data com vaga: selecionar a data no detalhe do pedido e verificar a reserva na Agenda de entregas.
- Testar usuário sem vínculo: não deve acessar a fila.
- Testar concorrência com duas sessões tentando reservar a última vaga.

## Limitações ainda não homologadas

- Reagendamento após cancelamento, retorno/desembarque avançado e capacidade por volume/peso.
- Testes reais multiusuário, backup/restauração e integração fiscal/financeira externa.
- Compilação Vite no Windows pendente após a entrega deste pacote.

Não inserir dados reais de clientes sem homologação da segurança e do processo operacional.
