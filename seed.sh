#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log()  { echo -e "${CYAN}[SEED]${NC} $1"; }

N_USERS="${1:-5}"
KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8180}"
TOKEN_URL="$KEYCLOAK_URL/realms/tcc/protocol/openid-connect/token"
CLIENT_SECRET="${POSTMAN_SECRET:-postman-secret-123}"
TEST_USER="${TEST_USER:-testuser}"
TEST_PASS="${TEST_USER_PASS:-testpass}"

if [ -f .env ]; then
  set -a; source .env; set +a
fi

log "Obtendo token ($TEST_USER)..."
TOKEN=$(curl -s -X POST "$TOKEN_URL" \
  -u "postman:${POSTMAN_SECRET:-postman-secret-123}" \
  -d "grant_type=password" -d "username=$TEST_USER" -d "password=$TEST_PASS" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))")
if [ -z "$TOKEN" ]; then
  fail "Não foi possível obter token."
  exit 1
fi
AUTH="Authorization: Bearer $TOKEN"
CT="Content-Type: application/json"

RUN_ID="$(date +%s)"
CONSENTED_PCT=70
REVOKED_PCT=40

log "Gerando $N_USERS usuários (run_id=$RUN_ID)..."
UIDS=()
for i in $(seq 1 "$N_USERS"); do
  DOC=$((10000000000 + RUN_ID % 100000000 + i * 7))
  DOC=$(printf '%011d' "$DOC")
  RESP=$(curl -s -X POST http://localhost:8083/api/v1/users \
    -H "$AUTH" -H "$CT" \
    -d "{\"fullName\":\"Titular $i (run $RUN_ID)\",\"email\":\"titular$RUN_ID$i@demo.com\",\"documentNumber\":\"$DOC\",\"birthDate\":\"1995-01-01\"}")
  ID=$(echo "$RESP" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin); print(d.get('id',''))
except Exception: print('')")
  if [ -n "$ID" ]; then
    UIDS+=("$ID")
  else
    warn "Falha ao criar usuário $i: $(echo "$RESP" | head -c 200)"
  fi
done
log "${#UIDS[@]} usuários criados: ${UIDS[*]}"

CONSENTED=0; REVOKED=0; ALLOWED=0; DENIED=0
for TID in "${UIDS[@]}"; do
  if [ $((RANDOM % 100)) -ge $CONSENTED_PCT ]; then
    warn "Usuário #$TID: SEM consentimento (vai gerar DENIED)"
    curl -s -o /dev/null "http://localhost:8084/api/v1/billing/users/$TID/billing/0/with-profile" \
      -H "$AUTH" -H "X-Purpose: BILLING" -H "X-Data-Categories: FINANCIAL_DATA,PERSONAL_DATA" || true
    continue
  fi
  CONSENTED=$((CONSENTED + 1))

  log "Usuário #$TID: concedendo consentimento completo..."
  curl -s -o /dev/null -X POST http://localhost:8080/api/v1/consent \
    -H "$AUTH" -H "$CT" \
    -d "{\"ownerId\":$TID,\"authorizations\":[{\"dataCategory\":\"PERSONAL_DATA\",\"purposes\":[\"BILLING\",\"PROMOTION\",\"ANALYTICS\"]},{\"dataCategory\":\"CONTRACT_DATA\",\"purposes\":[\"BILLING\"]},{\"dataCategory\":\"USAGE_DATA\",\"purposes\":[\"PROMOTION\",\"ANALYTICS\"]},{\"dataCategory\":\"FINANCIAL_DATA\",\"purposes\":[\"BILLING\"]}],\"legalBasis\":\"CONSENT\",\"issuedBy\":{\"issuer\":\"USER\",\"id\":$TID}}"

  sleep 1

  log "Usuário #$TID: criando fatura e acessando com perfil (billing)..."
  BILL=$(curl -s -X POST http://localhost:8084/api/v1/billing \
    -H "$AUTH" -H "$CT" \
    -d "{\"dataSubjectId\":\"$TID\",\"description\":\"Fatura run $RUN_ID\",\"amount\":$(($TID * 37 % 500 + 50)).00}")
  BID=$(echo "$BILL" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin); print(d.get('id',''))
except Exception: print('')")
  if [ -n "$BID" ]; then
    CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:8084/api/v1/billing/$BID/with-profile" \
      -H "$AUTH" -H "X-Purpose: BILLING" -H "X-Data-Categories: FINANCIAL_DATA,PERSONAL_DATA")
    if [ "$CODE" = "200" ]; then ALLOWED=$((ALLOWED + 1)); else DENIED=$((DENIED + 1)); warn "  with-profile billing -> HTTP $CODE"; fi
  fi

  log "Usuário #$TID: consultando promoções com perfil (promotion)..."
  CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:8085/api/v1/promotions/$TID/with-profile" \
    -H "$AUTH" -H "X-Purpose: PROMOTION" -H "X-Data-Categories: USAGE_DATA")
  if [ "$CODE" = "200" ]; then ALLOWED=$((ALLOWED + 1)); else DENIED=$((DENIED + 1)); warn "  with-profile promotion -> HTTP $CODE"; fi

  if [ $((RANDOM % 100)) -lt $REVOKED_PCT ]; then
    log "Usuário #$TID: revogando PROMOTION/USAGE_DATA e tentando acessar de novo..."
    curl -s -o /dev/null -X POST "http://localhost:8080/api/v1/consent/$TID/revoke" \
      -H "$AUTH" -H "$CT" \
      -d "{\"ownerId\":$TID,\"authorizations\":[{\"dataCategory\":\"USAGE_DATA\",\"purposes\":[\"PROMOTION\"]}],\"reason\":\"Revogado pelo seed\",\"issuedBy\":{\"issuer\":\"USER\",\"id\":$TID}}"
    sleep 1
    CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:8085/api/v1/promotions/$TID/with-profile" \
      -H "$AUTH" -H "X-Purpose: PROMOTION" -H "X-Data-Categories: USAGE_DATA")
    if [ "$CODE" = "200" ]; then ALLOWED=$((ALLOWED + 1)); else DENIED=$((DENIED + 1)); REVOKED=$((REVOKED + 1)); fi
  fi
done

log "Criando promoções demo..."
curl -s -o /dev/null -X POST http://localhost:8085/api/v1/promotions \
  -H "$AUTH" -H "$CT" -H "X-Purpose: PROMOTION" -H "X-Data-Categories: USAGE_DATA" \
  -d "{\"dataSubjectId\":\"1\",\"name\":\"Mega Oferta Run $RUN_ID\",\"description\":\"Gerada pelo seed\",\"discountPercent\":25.0,\"startDate\":\"2026-09-01\",\"endDate\":\"2026-12-31\",\"targetSegment\":\"PREMIUM\"}" >/dev/null || true

echo ""
echo -e "${GREEN}========================================================${NC}"
echo -e "${GREEN}  Massa gerada!${NC}"
echo -e "${GREEN}========================================================${NC}"
echo ""
echo -e "  Usuários criados:       ${YELLOW}${#UIDS[@]}${NC}"
echo -e "  Com consentimento:      ${GREEN}$CONSENTED${NC}"
echo -e "  Acessos ALLOWED:        ${GREEN}$ALLOWED${NC}"
echo -e "  Acessos DENIED:         ${RED}$DENIED${NC}"
echo -e "  Revogações geradas:     ${YELLOW}$REVOKED${NC}"
echo ""
echo -e "  Veja os acontecimentos no console:"
echo -e "    Auditoria → Trilha do Titular  (evidências ALLOWED/DENIED)"
echo -e "    Linha do Tempo                 (consentimentos + acessos)"
echo ""
