# Explorar o projeto em uma demonstração

[Guia de execução](../README.md#executar-localmente) · [Arquitetura](architecture.md)

## Preparar

Inicie a stack pelo guia central, abra `http://localhost:8087` e use o perfil `testuser`. Gere dados fictícios pela página **Massa de Dados** ou por `bash seed.sh 10`.

## Conceder, usar, revogar e investigar

1. Escolha um titular e uma combinação de categoria e finalidade na tela de consentimentos. Guarde essa combinação para repetir o mesmo contexto nas chamadas seguintes.
2. Conceda o consentimento. Confira o estado e o evento no histórico.
3. Faça uma consulta protegida pelo cenário de cobrança ou promoções que use essa combinação. Confira a resposta e a decisão registrada na auditoria.
4. Revogue o consentimento usado. Aguarde a confirmação do comando e repita a mesma consulta protegida. A policy que depende desse consentimento deve negar a nova tentativa.
5. Abra **Linha do Tempo**, selecione o titular e expanda as decisões. Compare concessão, revogação, horários e registros por serviço. O destaque **Neste acesso** indica o último evento de concessão ou revogação até aquele instante.
6. Use o identificador de trace para relacionar as decisões de um mesmo fluxo. Se o registro ainda não aparecer, aguarde a propagação assíncrona e atualize a consulta.
7. Alterne entre `auditor1` e `operador1` para explorar o acesso às consultas de auditoria de acordo com o papel.

## O que observar

Uma decisão permitida antes da revogação pode continuar coerente com o histórico mesmo quando o estado atual já está revogado. Esse é o motivo para preservar eventos e relacioná-los ao instante da decisão.

Uma negativa indica que o caminho protegido bloqueou a tentativa. O rótulo `VIOLATION` do protótipo deve ser interpretado junto das decisões individuais. Uma autorização permitida também não garante que a operação de negócio foi concluída.

A demonstração é exploratória. Os resultados dependem dos dados, políticas e componentes em execução; este roteiro não substitui uma suíte de testes nem um relatório de desempenho.
