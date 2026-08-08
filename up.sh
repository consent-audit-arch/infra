#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}[UP]${NC} $1"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }

ENV_FILE="$SCRIPT_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  fail "Arquivo $ENV_FILE não encontrado."
  exit 1
fi
set -a
source "$ENV_FILE"
set +a

BASE="-f docker-compose.base.yml"
MOD1="-f docker-compose.module1.yml"
MOD2="-f docker-compose.module2.yml"
MOD3="-f docker-compose.module3.yml"
FRONT="-f docker-compose.frontend.yml"
ALL="$BASE $MOD1 $MOD2 $MOD3 $FRONT"

KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8180}"

# ── 1. Rede ──────────────────────────────────────────────────────────────────

if docker network inspect consent-net >/dev/null 2>&1; then
  ok "Rede consent-net já existe"
else
  log "Criando rede consent-net..."
  docker network create consent-net >/dev/null
  ok "Rede consent-net criada"
fi

# ── 2. Imagem do frontend ────────────────────────────────────────────────────

log "Construindo imagem do frontend (${FRONTEND_IMAGE:-consent-console:latest})..."
docker build -t "${FRONTEND_IMAGE:-consent-console:latest}" ../frontend
ok "Imagem do frontend construída"

# ── 3. Subir a stack ─────────────────────────────────────────────────────────

log "Subindo toda a stack (base + módulos 1/2/3 + frontend)..."
docker compose $ALL up -d --force-recreate
ok "Stack iniciada"

# ── 4. Aguardar Keycloak saudável ────────────────────────────────────────────

log "Aguardando Keycloak ficar saudável..."
KC_OK=0
for i in $(seq 1 40); do
  if curl -sf "$KEYCLOAK_URL/health/ready" >/dev/null 2>&1; then
    KC_OK=1
    break
  fi
  sleep 3
done

if [ "$KC_OK" -ne 1 ]; then
  fail "Keycloak não respondeu após 40 tentativas."
  exit 1
fi
ok "Keycloak pronto ($KEYCLOAK_URL)"

# ── 5. Configurar Keycloak (realm, clients, roles, testuser) ────────────────

log "Executando setup do Keycloak..."
./setup-keycloak.sh

# ── 6. Aguardar serviços essenciais ──────────────────────────────────────────

wait_health() {
  local name="$1"; local url="$2"
  for i in $(seq 1 20); do
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)
    if [ "$code" != "000" ]; then
      ok "$name saudável (HTTP $code)"
      return 0
    fi
    sleep 3
  done
  warn "$name não respondeu no tempo esperado — verifique os logs."
}

wait_health "user-service"      "http://localhost:8083/actuator/health"
wait_health "audit-service"     "http://localhost:8086/actuator/health"
wait_health "consent-command"   "http://localhost:8080/actuator/health"
wait_health "dashboard-service" "http://localhost:8082/actuator/health"

# ── 7. Resumo ────────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}========================================================${NC}"
echo -e "${GREEN}  Stack pronta!${NC}"
echo -e "${GREEN}========================================================${NC}"
echo ""
echo -e "  Console (frontend):  ${CYAN}http://localhost:8087${NC}"
echo -e "  Keycloak:            ${CYAN}$KEYCLOAK_URL${NC}"
echo -e "  Kafka UI:            ${CYAN}http://localhost:${KAFKA_UI_PORT:-8070}${NC}"
echo ""
echo -e "  Login do console:"
echo -e "    Usuário:  ${YELLOW}testuser${NC}"
echo -e "    Senha:    ${YELLOW}${TEST_USER_PASS:-testpass}${NC}"
echo ""
echo -e "${YELLOW}  Dica: antes da apresentação, gere dados:${NC}"
echo -e "    1. Opção A: ./seed.sh 10          (massa via CLI — usuários, consents, acessos)"
echo -e "    2. Opção B: console → 'Massa de Dados' (gera direto no navegador)"
echo -e "    3. Console → 'Linha do Tempo'      (consentimentos + acessos + prova por titular)"
echo -e "    4. Console → header 'Trocar usuário…' (testuser / auditor1 / operador1)"
echo ""
