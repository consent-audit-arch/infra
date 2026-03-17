# 🐳 infra

Docker Compose base do projeto TCC — Consent Context.

![Kafka KRaft](https://img.shields.io/badge/Kafka-KRaft-black) ![PostgreSQL 16](https://img.shields.io/badge/PostgreSQL-16-blue) ![MongoDB 7](https://img.shields.io/badge/MongoDB-7-green)

---

## Estrutura

```
infra/
├── docker-compose.yml
├── .env

```

---

## Pré-requisitos

- Docker + Docker Compose v2
- Arquivo `.env` configurado (ver seção abaixo)

---

## Configuração — `.env`

```env
# Postgres
POSTGRES_USER=admin
POSTGRES_PASSWORD=admin
POSTGRES_DB=event_db

# MongoDB
MONGO_USER=admin
MONGO_PASSWORD=admin

# Kafka KRaft — gere o CLUSTER_ID com:
# docker run --rm confluentinc/cp-kafka:7.6.0 kafka-storage random-uuid
KAFKA_CLUSTER_ID=<uuid-gerado>

# Kafka UI
KAFKA_UI_PORT=8080
```


## Comandos principais

```bash
# Subir infra
docker compose --profile X up -d

# Acompanhar logs
docker compose --profile X logs -f

# Parar
docker compose --profile X down

# Reset total (apaga volumes)
docker compose --profile X down -v

# Verificar status
docker compose --profile X ps
```

---

## Serviços

| Serviço       | Porta | Profile |
|---------------|-------|---------|
| PostgreSQL 16 | 5432  | consent |
| MongoDB 7     | 27017 | consent |
| Kafka (KRaft) | 9092  | consent |
| Kafka UI      | 8080  | consent |

---

## Kafka — Tópicos

`KAFKA_AUTO_CREATE_TOPICS_ENABLE=true` está ativo. Os tópicos são criados automaticamente na primeira publicação pelo producer.

| Tópico      | Contexto                                  |
|-------------|-------------------------------------------|
| ev-consent  | Consent Context — eventos de consentimento |

---

## Banco de dados

```
mongodb://admin:admin@localhost:27017
```

---

## Profiles

Cada contexto do projeto possui seu próprio profile, permitindo subir partes da infra de forma isolada.

| Profile | Contexto                    | Status    |
|---------|-----------------------------|-----------|
| consent | Consent Context (Módulo 1)  | ✅ Ativo  |
