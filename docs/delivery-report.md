# Relatório de Entrega — Tech Challenge Fase 3

FIAP · Pós-Tech · Projeto Kongroo (FIAP Cloud Games)

## Identificação

| Campo        | Valor                          |
| ------------ | ------------------------------ |
| Grupo        | 103                            |
| Participante | Jose Rogerio de Almeida Junior |
| RM           | rm371960                       |
| Discord      | José Rogério - RM371960        |

## Projeto

**Nome:** Kongroo / FIAP Cloud Games

Evolução dos microsserviços da Fase 2 para uma arquitetura **cloud-native**. Um **API Gateway
(Kong 3.9, DB-less)** passou a ser a única porta de entrada, validando o **JWT** emitido pelo
Identidade antes de encaminhar para os serviços. As notificações deixaram de ser um container e
viraram uma **função serverless (AWS Lambda, .NET 10)** acionada por uma fila **SQS** assinada nos
tópicos **SNS** publicados pelos serviços, com **DLQ** após três tentativas e implantação via **AWS
SAM** na conta **AWS Academy Learner Lab**. O transporte do **MassTransit** passou a ser
configurável (`Messaging__Transport`): RabbitMQ no Docker Compose e nos testes, **Amazon SQS/SNS** no
Kubernetes. A observabilidade usa **OpenTelemetry** expondo `/metrics` em formato Prometheus nos três
serviços, coletado pelo **Prometheus** e apresentado em um dashboard provisionado no **Grafana**. O
Catálogo ganhou persistência **NoSQL (MongoDB)** para avaliações de jogos (uma por cliente por jogo,
garantida por índice único) e **cache distribuído (Redis)** para as leituras de jogos, via
`HybridCache` com invalidação por tag em toda escrita.

## Links de Entrega

| Item                      | Link                                                        |
| ------------------------- | ----------------------------------------------------------- |
| Vídeo de apresentação     | `<preencher após a gravação>`                                |
| Documentação (guia geral) | github.com/almeidajr/Kongroo.Orchestration — `README.md`     |
| Documentação (arquitetura)| `ARCHITECTURE.md` (Kongroo.Orchestration)                    |

## Repositórios (GitHub, usuário `almeidajr`)

### Microsserviços

| Serviço      | Repositório                                | Último commit |
| ------------ | ------------------------------------------ | ------------- |
| Identidade   | github.com/almeidajr/Kongroo.Identity      | `<sha>`       |
| Catálogo     | github.com/almeidajr/Kongroo.Catalog       | `<sha>`       |
| Pagamentos   | github.com/almeidajr/Kongroo.Payments      | `<sha>`       |
| Notificações | github.com/almeidajr/Kongroo.Notifications | `<sha>`       |

### Orquestração

| Repositório                        | Link                                       | Último commit |
| ---------------------------------- | ------------------------------------------ | ------------- |
| Docker Compose + Kubernetes + Kong | github.com/almeidajr/Kongroo.Orchestration | `<sha>`       |

### Bibliotecas compartilhadas (Building Blocks)

| Biblioteca     | Repositório                                                | Último commit |
| -------------- | ---------------------------------------------------------- | ------------- |
| Domain         | github.com/almeidajr/Kongroo.BuildingBlocks.Domain         | `3526ea3`     |
| Application    | github.com/almeidajr/Kongroo.BuildingBlocks.Application    | `5b31ef2`     |
| Infrastructure | github.com/almeidajr/Kongroo.BuildingBlocks.Infrastructure | `f070312`     |

## Pacotes NuGet (nuget.org, `almeidajr`)

| Pacote                                | Versão | Link                                                    |
| ------------------------------------- | ------ | ------------------------------------------------------- |
| Kongroo.BuildingBlocks.Domain         | 0.1.0  | nuget.org/packages/Kongroo.BuildingBlocks.Domain         |
| Kongroo.BuildingBlocks.Application    | 0.2.0  | nuget.org/packages/Kongroo.BuildingBlocks.Application    |
| Kongroo.BuildingBlocks.Infrastructure | 0.2.0  | nuget.org/packages/Kongroo.BuildingBlocks.Infrastructure |

## Imagens Docker (Docker Hub, `josealmeidajr`)

Perfil: hub.docker.com/u/josealmeidajr

| Imagem                | Tag     | Link                                            |
| --------------------- | ------- | ----------------------------------------------- |
| kongroo-identity      | 0.1.0   | hub.docker.com/r/josealmeidajr/kongroo-identity |
| kongroo-catalog       | 0.1.0   | hub.docker.com/r/josealmeidajr/kongroo-catalog  |
| kongroo-payments      | 0.1.0   | hub.docker.com/r/josealmeidajr/kongroo-payments |
| kongroo-notifications | 0.0.5 † | hub.docker.com/r/josealmeidajr/kongroo-notifications |

† Notificações não publica mais imagem: na Fase 3 o serviço virou uma função **AWS Lambda** implantada
por SAM (stack `kongroo-notifications`, região `us-east-1`). A tag 0.0.5 é o último container da Fase 2.

## Recursos AWS (AWS Academy Learner Lab, `us-east-1`)

| Recurso                 | Nome                                                                |
| ----------------------- | ------------------------------------------------------------------- |
| Stack CloudFormation    | `kongroo-notifications` (AWS SAM)                                   |
| Função Lambda           | `kongroo-notifications` (runtime `dotnet10`, execução com `LabRole`) |
| Tópicos SNS             | `kongroo-user-created`, `kongroo-order-placed`, `kongroo-payment-processed` |
| Filas SQS               | `kongroo-notifications` (+ DLQ `kongroo-notifications-dlq`), `catalog-payment-processed-integration-event`, `payments-order-placed-integration-event` |

## Requisitos da Fase 3 e onde estão

| Requisito                    | Implementação                                                                                          |
| ---------------------------- | ------------------------------------------------------------------------------------------------------ |
| API Gateway                  | Kong 3.9 DB-less (`k8s/kong/kong.yaml`), plugin `jwt` validando o token do Identidade, porta 8000        |
| Função serverless            | AWS Lambda .NET 10 acionada por SQS, implantada com SAM (`Kongroo.Notifications/template.yaml`)          |
| Monitoramento / observabilidade | OpenTelemetry → `/metrics` (Prometheus) nos três serviços + métricas do Kong → Prometheus → dashboard Grafana `kongroo` |
| Banco NoSQL                  | MongoDB no Catálogo: avaliações de jogos, índice único `ux_reviews_game_customer` (409 na segunda avaliação) |
| Cache distribuído            | Redis no Catálogo via `HybridCache` (5 min distribuído / 1 min em processo), invalidação pela tag `games` |

## Como executar

O `README.md` do repositório de orquestração é o guia central: traz os dois modos de execução
(Docker Compose com RabbitMQ, ou Kubernetes com AWS SQS/SNS), as portas, os scripts
(`sync.ps1`, `scripts/check.ps1`, `scripts/demo.ps1`, `scripts/set-aws-credentials.ps1`) e o
passo a passo da sessão do Learner Lab.

---

Kongroo · FIAP Cloud Games · Tech Challenge Fase 3 · Grupo 103
