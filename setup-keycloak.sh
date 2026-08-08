#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}[KC]${NC} $1" >&2; }
ok()   { echo -e "${GREEN}[OK]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
fail() { echo -e "${RED}[FAIL]${NC} $1" >&2; }

source "$ENV_FILE"

KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8180}"
REALM="${KEYCLOAK_REALM:-tcc}"
KC_ADMIN="${KEYCLOAK_ADMIN_USER:-admin}"
KC_ADMIN_PASS="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
POSTMAN_CLIENT_SECRET="${POSTMAN_CLIENT_SECRET:-postman-secret-123}"
TEST_USER_PASS="${TEST_USER_PASS:-testpass}"

# ── Helpers ──────────────────────────────────────────────────────────────────

get_admin_token() {
  curl -s -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
    -d "grant_type=password" \
    -d "client_id=admin-cli" \
    -d "username=$KC_ADMIN" \
    -d "password=$KC_ADMIN_PASS" \
    | jq -r '.access_token'
}

kc_admin() {
  local method="$1"; local path="$2"; shift 2
  curl -sf -X "$method" "$KEYCLOAK_URL$path" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    "$@"
}

resource_exists() {
  local path="$1"
  local result
  result=$(curl -sf -X GET "$KEYCLOAK_URL$path" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" 2>/dev/null) || return 1
  [ "$result" != "[]" ] && [ "$result" != "null" ]
}

get_id_from_list() {
  echo "$1" | jq -r '.[0].id // empty'
}

# ── Wait for Keycloak ────────────────────────────────────────────────────────

log "Aguardando Keycloak ficar saudável..."
for i in $(seq 1 30); do
  if curl -sf "$KEYCLOAK_URL/health/ready" > /dev/null 2>&1; then
    ok "Keycloak pronto!"
    break
  fi
  if [ "$i" -eq 30 ]; then
    fail "Keycloak não respondeu após 30 tentativas"
    exit 1
  fi
  sleep 3
done

log "Obtendo token de admin..."
TOKEN=$(get_admin_token)
ok "Token obtido"

# ── Realm ────────────────────────────────────────────────────────────────────

log "Verificando realm '$REALM'..."
if resource_exists "/admin/realms/$REALM"; then
  ok "Realm '$REALM' já existe"
else
  log "Criando realm '$REALM'..."
  kc_admin POST /admin/realms \
    -d "{\"realm\": \"$REALM\", \"enabled\": true}"
  ok "Realm '$REALM' criado"
fi

# Tokens longos para a apresentação (evita re-login a cada 5 min)
kc_admin PUT "/admin/realms/$REALM" \
  -d "{
    \"realm\": \"$REALM\",
    \"enabled\": true,
    \"accessTokenLifespan\": ${KEYCLOAK_ACCESS_TOKEN_LIFESPAN:-3600},
    \"ssoSessionIdleTimeout\": 7200,
    \"ssoSessionMaxLifespan\": 86400
  }" > /dev/null
ok "Realm '$REALM' com tokens de ${KEYCLOAK_ACCESS_TOKEN_LIFESPAN:-3600}s"

# ── Realm Roles ───────────────────────────────────────────────────────────────

create_realm_role() {
  local role="$1"
  if resource_exists "/admin/realms/$REALM/roles/$role"; then
    ok "Role '$role' já existe"
  else
    kc_admin POST "/admin/realms/$REALM/roles" \
      -d "{\"name\": \"$role\", \"composite\": false}"
    ok "Role '$role' criada"
  fi
}

log "Criando realm roles..."
create_realm_role "USER_READ"
create_realm_role "BILLING_READ"
create_realm_role "PERSONAL_DATA_READ"
create_realm_role "CONTRACT_DATA_READ"
create_realm_role "USAGE_DATA_READ"
create_realm_role "FINANCIAL_DATA_READ"
create_realm_role "PROMOTION_READ"
create_realm_role "AUDITOR"

# ── Client helpers ───────────────────────────────────────────────────────────

get_client_id() {
  local client_id="$1"
  kc_admin GET "/admin/realms/$REALM/clients?clientId=$client_id" | jq -r '.[0].id // empty'
}

get_service_account_user_id() {
  local client_db_id="$1"
  kc_admin GET "/admin/realms/$REALM/clients/$client_db_id/service-account-user" | jq -r '.id // empty'
}

assign_realm_roles_to_user() {
  local user_id="$1"
  shift
  local roles_json="["
  local sep=""
  for role in "$@"; do
    local role_data
    role_data=$(kc_admin GET "/admin/realms/$REALM/roles/$role")
    local role_name; role_name=$(echo "$role_data" | jq -r '.name')
    local role_id;   role_id=$(echo "$role_data" | jq -r '.id')
    roles_json+="${sep}{\"id\": \"$role_id\", \"name\": \"$role_name\"}"
    sep=","
  done
  roles_json+="]"

  local current
  current=$(kc_admin GET "/admin/realms/$REALM/users/$user_id/role-mappings/realm" 2>/dev/null || echo "[]")
  local missing
  missing=$(echo "$roles_json" | jq -c --argjson current "$current" '
    [.[] | select(.name as $n | $current | map(.name) | index($n) | not)]
  ')

  if [ "$(echo "$missing" | jq length)" -eq 0 ]; then
    ok "Roles já atribuídas ao usuário"
    return
  fi

  kc_admin POST "/admin/realms/$REALM/users/$user_id/role-mappings/realm" \
    -d "$missing" > /dev/null
  ok "Roles '$*' atribuídas ao usuário"
}

# ── Upsert public SPA client (consent-console) ───────────────────────────────

upsert_console_client() {
  local client_id="$1"
  local redirect_uris="$2"
  local web_origins="$3"

  local existing_id
  existing_id=$(get_client_id "$client_id")

  if [ -n "$existing_id" ]; then
    log "Client '$client_id' já existe (id=$existing_id) — atualizando..."
    kc_admin PUT "/admin/realms/$REALM/clients/$existing_id" \
      -d "{
        \"id\": \"$existing_id\",
        \"clientId\": \"$client_id\",
        \"enabled\": true,
        \"publicClient\": true,
        \"serviceAccountsEnabled\": false,
        \"directAccessGrantsEnabled\": true,
        \"standardFlowEnabled\": true,
        \"protocol\": \"openid-connect\",
        \"redirectUris\": $redirect_uris,
        \"webOrigins\": $web_origins,
        \"attributes\": {
          \"pkce.code.challenge.method\": \"S256\"
        }
      }" > /dev/null
    ok "Client '$client_id' atualizado (PKCE S256)"
    echo "$existing_id"
    return
  fi

  log "Criando client público '$client_id'..."
  local resp
  resp=$(kc_admin POST "/admin/realms/$REALM/clients" \
    -d "{
      \"clientId\": \"$client_id\",
      \"enabled\": true,
      \"publicClient\": true,
      \"serviceAccountsEnabled\": false,
      \"directAccessGrantsEnabled\": true,
      \"standardFlowEnabled\": true,
      \"protocol\": \"openid-connect\",
      \"redirectUris\": $redirect_uris,
      \"webOrigins\": $web_origins,
      \"attributes\": {
        \"pkce.code.challenge.method\": \"S256\"
      }
    }" 2>&1) || {
    fail "Erro ao criar client '$client_id': $resp"
    return 1
  }

  local new_id
  new_id=$(get_client_id "$client_id")
  ok "Client '$client_id' criado (id=$new_id)"
  echo "$new_id"
}

# ── Upsert client (create or update secret) ──────────────────────────────────

upsert_client() {
  local client_id="$1"
  local secret="$2"
  local direct_access="${3:-false}"
  local service_accounts="${4:-false}"

  local existing_id
  existing_id=$(get_client_id "$client_id")

  if [ -n "$existing_id" ]; then
    log "Client '$client_id' já existe (id=$existing_id) — atualizando secret..."
    kc_admin PUT "/admin/realms/$REALM/clients/$existing_id" \
      -d "{
        \"id\": \"$existing_id\",
        \"clientId\": \"$client_id\",
        \"secret\": \"$secret\",
        \"enabled\": true,
        \"publicClient\": false,
        \"serviceAccountsEnabled\": $service_accounts,
        \"directAccessGrantsEnabled\": $direct_access,
        \"standardFlowEnabled\": false,
        \"protocol\": \"openid-connect\"
      }" > /dev/null
    ok "Client '$client_id' atualizado com nova secret"
    echo "$existing_id"
    return
  fi

  log "Criando client '$client_id'..."
  local resp
  resp=$(kc_admin POST "/admin/realms/$REALM/clients" \
    -d "{
      \"clientId\": \"$client_id\",
      \"secret\": \"$secret\",
      \"enabled\": true,
      \"publicClient\": false,
      \"serviceAccountsEnabled\": $service_accounts,
      \"directAccessGrantsEnabled\": $direct_access,
      \"standardFlowEnabled\": false,
      \"protocol\": \"openid-connect\"
    }" 2>&1) || {
    fail "Erro ao criar client '$client_id': $resp"
    return 1
  }

  local new_id
  new_id=$(get_client_id "$client_id")
  ok "Client '$client_id' criado (id=$new_id)"
  echo "$new_id"
}

# ── Setup clients ────────────────────────────────────────────────────────────

log "Criando/atualizando clients..."

BILLING_CLIENT_ID=$(upsert_client "billing-service" "$BILLING_SERVICE_CLIENT_SECRET" false true)
USER_CLIENT_ID=$(upsert_client "user-service" "$USER_SERVICE_CLIENT_SECRET" false true)
POSTMAN_CLIENT_ID=$(upsert_client "postman" "$POSTMAN_CLIENT_SECRET" true false)
CONSENT_COMMAND_CLIENT_ID=$(upsert_client "consent-command-service" "${CONSENT_COMMAND_CLIENT_SECRET:-consent-command-secret}" false true)
CONSENT_QUERY_CLIENT_ID=$(upsert_client "consent-query-service" "${CONSENT_QUERY_CLIENT_SECRET:-consent-query-secret}" false true)
DASHBOARD_CLIENT_ID=$(upsert_client "dashboard-service" "${DASHBOARD_CLIENT_SECRET:-dashboard-secret}" false true)
PROMOTION_CLIENT_ID=$(upsert_client "promotion-service" "${PROMOTION_SERVICE_CLIENT_SECRET:-promotion-secret}" false true)
AUDIT_CLIENT_ID=$(upsert_client "audit-service" "${AUDIT_SERVICE_CLIENT_SECRET:-audit-secret}" false true)

# SPA frontend (Authorization Code + PKCE, public client)
CONSOLE_CLIENT_ID=$(upsert_console_client "consent-console" \
  '["http://localhost:5173/*", "http://localhost:8087/*", "http://localhost/*"]' \
  '["http://localhost:5173", "http://localhost:8087", "http://localhost"]')

# ── Assign roles to service accounts ─────────────────────────────────────────

log "Atribuindo roles às service accounts..."

# billing-service service account → needs USER_READ, BILLING_READ, PERSONAL_DATA_READ, FINANCIAL_DATA_READ, CONTRACT_DATA_READ, USAGE_DATA_READ
BILLING_SA_ID=$(get_service_account_user_id "$BILLING_CLIENT_ID")
if [ -n "$BILLING_SA_ID" ]; then
  assign_realm_roles_to_user "$BILLING_SA_ID" \
    "USER_READ" "BILLING_READ" \
    "PERSONAL_DATA_READ" "FINANCIAL_DATA_READ" \
    "CONTRACT_DATA_READ" "USAGE_DATA_READ"
else
  warn "Service account do billing-service não encontrada"
fi

# user-service service account → no roles needed (resource server only)
# consent-command-service → no roles needed
# consent-query-service → no roles needed

# promotion-service service account → USER_READ (to call user-service), PROMOTION_READ (OPA sidecar validates roles from caller token)
PROMOTION_SA_ID=$(get_service_account_user_id "$PROMOTION_CLIENT_ID")
if [ -n "$PROMOTION_SA_ID" ]; then
  assign_realm_roles_to_user "$PROMOTION_SA_ID" "USER_READ" "PROMOTION_READ"
else
  warn "Service account do promotion-service não encontrada"
fi

# audit-service service account → no roles needed (resource server)

# dashboard-service service account → PROMOTION_READ
DASHBOARD_SA_ID=$(get_service_account_user_id "$DASHBOARD_CLIENT_ID")
if [ -n "$DASHBOARD_SA_ID" ]; then
  assign_realm_roles_to_user "$DASHBOARD_SA_ID" "PROMOTION_READ"
else
  warn "Service account do dashboard-service não encontrada"
fi

# ── Create test user ─────────────────────────────────────────────────────────

log "Criando usuário de teste..."

TEST_USER_ID=$(kc_admin GET "/admin/realms/$REALM/users?username=testuser" | jq -r '.[0].id // empty')

if [ -n "$TEST_USER_ID" ]; then
  ok "Usuário 'testuser' já existe (id=$TEST_USER_ID)"
else
  kc_admin POST "/admin/realms/$REALM/users" \
    -d "{
      \"username\": \"testuser\",
      \"email\": \"testuser@example.com\",
      \"firstName\": \"Test\",
      \"lastName\": \"User\",
      \"enabled\": true,
      \"credentials\": [{\"type\": \"password\", \"value\": \"$TEST_USER_PASS\", \"temporary\": false}]
    }" > /dev/null
  TEST_USER_ID=$(kc_admin GET "/admin/realms/$REALM/users?username=testuser" | jq -r '.[0].id')
  ok "Usuário 'testuser' criado (id=$TEST_USER_ID)"
fi

assign_realm_roles_to_user "$TEST_USER_ID" \
  "USER_READ" "BILLING_READ" "PERSONAL_DATA_READ" "FINANCIAL_DATA_READ" \
  "CONTRACT_DATA_READ" "USAGE_DATA_READ" "PROMOTION_READ" "AUDITOR"

# ── Create demo users (para o seletor do console) ─────────────────────────────

upsert_demo_user() {
  local username="$1"; local first="$2"; local last="$3"
  local uid
  uid=$(kc_admin GET "/admin/realms/$REALM/users?username=$username" | jq -r '.[0].id // empty')
  if [ -n "$uid" ]; then
    ok "Usuário demo '$username' já existe"
  else
    kc_admin POST "/admin/realms/$REALM/users" \
      -d "{
        \"username\": \"$username\",
        \"email\": \"$username@example.com\",
        \"firstName\": \"$first\",
        \"lastName\": \"$last\",
        \"enabled\": true,
        \"credentials\": [{\"type\": \"password\", \"value\": \"$TEST_USER_PASS\", \"temporary\": false}]
      }" > /dev/null
    uid=$(kc_admin GET "/admin/realms/$REALM/users?username=$username" | jq -r '.[0].id')
    ok "Usuário demo '$username' criado"
  fi
  echo "$uid"
}

DEMO_AUDITOR_ID=$(upsert_demo_user "auditor1" "Auditor" "LGPD")
assign_realm_roles_to_user "$DEMO_AUDITOR_ID" \
  "USER_READ" "BILLING_READ" "PROMOTION_READ" "AUDITOR"

DEMO_OPERATOR_ID=$(upsert_demo_user "operador1" "Operador" "Comercial")
assign_realm_roles_to_user "$DEMO_OPERATOR_ID" \
  "USER_READ" "PROMOTION_READ"

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}========================================================${NC}"
echo -e "${GREEN}  Keycloak configurado com sucesso!${NC}"
echo -e "${GREEN}========================================================${NC}"
echo ""
echo "  Realm:         $REALM"
echo "  Admin console: $KEYCLOAK_URL/admin"
echo ""
echo -e "${CYAN}  Clients:${NC}"
echo "    billing-service"
echo "      Roles:  USER_READ, BILLING_READ, PERSONAL_DATA_READ, FINANCIAL_DATA_READ, CONTRACT_DATA_READ, USAGE_DATA_READ"
echo ""
echo "    user-service"
echo "      Roles:  (resource server)"
echo ""
echo "    consent-command-service"
echo "      Roles:  (resource server)"
echo ""
echo "    consent-query-service"
echo "      Roles:  (resource server)"
echo ""
echo "    dashboard-service"
echo "      Roles:  PROMOTION_READ"
echo ""
echo "    promotion-service"
echo "      Roles:  USER_READ, PROMOTION_READ"
echo ""
echo "    audit-service"
echo "      Roles:  (resource server)"
echo ""
echo "    consent-console (SPA)"
echo "      Flow:   Authorization Code + PKCE (S256), public client"
echo "      Redirect: http://localhost:5173/* | http://localhost:8087/*"
echo ""
echo "    postman"
echo "      Grant:  password (direct_access)"
echo ""
echo -e "${CYAN}  Test User:${NC}"
echo "    Username: testuser"
echo "    Password: $TEST_USER_PASS"
echo "    Roles:    USER_READ, BILLING_READ, PERSONAL_DATA_READ, FINANCIAL_DATA_READ, CONTRACT_DATA_READ, USAGE_DATA_READ, PROMOTION_READ, AUDITOR"
echo ""
echo -e "${YELLOW}  Exemplo de token (password grant):${NC}"
echo "    curl -s -X POST $KEYCLOAK_URL/realms/$REALM/protocol/openid-connect/token \\"
echo "      -u postman:$POSTMAN_CLIENT_SECRET \\"
echo "      -d 'grant_type=password' \\"
echo "      -d 'username=testuser' \\"
echo "      -d 'password=$TEST_USER_PASS' \\"
echo "      | jq -r '.access_token'"
echo ""
echo -e "${YELLOW}  Exemplo de token (client_credentials):${NC}"
echo "    curl -s -X POST $KEYCLOAK_URL/realms/$REALM/protocol/openid-connect/token \\"
echo "      -u billing-service:$BILLING_SERVICE_CLIENT_SECRET \\"
echo "      -d 'grant_type=client_credentials' \\"
echo "      | jq -r '.access_token'"
echo ""
