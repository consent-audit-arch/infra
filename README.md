# infra

Docker Compose do projeto TCC — Consentimento LGPD.

## Estrutura

```
infra/
  .env                              # Variáveis de ambiente
  docker-compose.base.yml           # Kafka (KRaft) + Kafka UI
  docker-compose.module1.yml        # Consent Context: postgres, mongo, serviços
  docker-compose.module2.yml        # User + Keycloak: postgres-user, keycloak, OPA
```

## Pré-requisitos

- Docker + Docker Compose v2
- Arquivo `.env` configurado
- Rede `consent-net` criada:

```bash
docker network create consent-net
```

## Comandos

### Subir tudo (infra base + módulo 1 + módulo 2)

```bash
docker compose -f docker-compose.base.yml -f docker-compose.module1.yml -f docker-compose.module2.yml up -d
```

### Subir apenas um módulo

```bash
# Infra base (Kafka)
docker compose -f docker-compose.base.yml up -d

# Módulo 1 — Consent Context (postgres, mongo, command, query, dashboard + sidecars OPA)
docker compose -f docker-compose.module1.yml up -d

# Módulo 2 — User Service + Keycloak (postgres-user, keycloak + OPA sidecar)
docker compose -f docker-compose.module2.yml up -d

# Apenas OPA do user-service (se o resto já estiver rodando)
docker compose -f docker-compose.module2.yml up -d opa-user-service
```

### Parar

```bash
# Tudo
docker compose -f docker-compose.base.yml -f docker-compose.module1.yml -f docker-compose.module2.yml down

# Apenas um módulo
docker compose -f docker-compose.module1.yml down
docker compose -f docker-compose.module2.yml down
```

### Logs

```bash
docker compose -f docker-compose.module1.yml logs -f
docker compose -f docker-compose.module2.yml logs -f opa-user-service
```

### Reset total (apaga volumes)

```bash
docker compose -f docker-compose.module1.yml down -v
docker compose -f docker-compose.module2.yml down -v
```

### Status

```bash
docker compose -f docker-compose.module1.yml ps
docker compose -f docker-compose.module2.yml ps
```

## Serviços

### Infra Base

| Serviço       | Porta | Arquivo         |
|---------------|-------|-----------------|
| Kafka (KRaft) | 9092  | base.yml        |
| Kafka UI      | 8070  | base.yml        |

### Módulo 1 — Consent Context

| Serviço                | Porta     | Arquivo       |
|------------------------|-----------|---------------|
| PostgreSQL             | 5432      | module1.yml   |
| MongoDB                | 27017     | module1.yml   |
| consent-command-service| 8080      | module1.yml   |
| OPA (command)          | — (sidecar)| module1.yml   |
| consent-query-service  | 8081      | module1.yml   |
| OPA (query)            | — (sidecar)| module1.yml   |
| dashboard-service      | 8082      | module1.yml   |
| OPA (dashboard)        | — (sidecar)| module1.yml   |

### Módulo 2 — User + Billing + Keycloak

| Serviço                | Porta externa | Arquivo       |
|------------------------|--------------|-----------------|
| PostgreSQL (user)      | 5433         | module2.yml     |
| PostgreSQL (billing)   | 5434         | module2.yml     |
| PostgreSQL (keycloak)  | —            | module2.yml     |
| Keycloak               | 8180         | module2.yml     |
| user-service           | 8083         | module2.yml     |
| OPA (user-service)     | — (sidecar)  | module2.yml     |
| billing-service        | 8084         | module2.yml     |
| OPA (billing-service)  | — (sidecar)  | module2.yml     |

## Kafka — Tópicos

`KAFKA_AUTO_CREATE_TOPICS_ENABLE=true` ativado. Os tópicos são criados automaticamente.

| Tópico      | Contexto                                  |
|-------------|-------------------------------------------|
| ev-consent  | Consent Context — eventos de consentimento |

## Rede

Todos os serviços compartilham a rede `consent-net`. OPA sidecars usam `network_mode: service:<servico>`.

## Credenciais

Valores sensíveis são injetados via `.env` (não versionado). Consulte `.env.example` como referência.

## Policies OPA

Cada serviço possui sua própria policy Rego no diretório do serviço:

```
user-service/opa/policies/policy.rego
billing-service/opa/policies/policy.rego
consent-command-service/opa/policies/policy.rego
consent-query-service/opa/policies/policy.rego
dashboard-service/opa/policies/policy.rego
```
