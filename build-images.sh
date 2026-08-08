#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

ENV_FILE="infra/.env"
DEFAULT_TAG="latest"

if [ -f "$ENV_FILE" ]; then
    echo -e "${CYAN}[INFO]${NC} Carregando $ENV_FILE..."
    set -a
    source "$ENV_FILE"
    set +a
fi

SERVICE_MVN_DIR() {
    case "$1" in
        billing-service)         echo "billing-service" ;;
        user-service)            echo "user-service/user-service" ;;
        consent-command-service) echo "consent-command-service/consent-command-service" ;;
        consent-query-service)   echo "consent-query-service/consent_query_service" ;;
        dashboard-service)       echo "dashboard-service/dashboard_query_service" ;;
        promotion-service)       echo "promotion-service" ;;
        audit-service)           echo "audit-service" ;;
    esac
}

SERVICE_DOCKERFILE() {
    case "$1" in
        billing-service)         echo "billing-service/Dockerfile" ;;
        user-service)            echo "user-service/user-service/Dockerfile" ;;
        consent-command-service) echo "consent-command-service/Dockerfile" ;;
        consent-query-service)   echo "consent-query-service/Dockerfile" ;;
        dashboard-service)       echo "dashboard-service/Dockerfile" ;;
        promotion-service)       echo "promotion-service/Dockerfile" ;;
        audit-service)           echo "audit-service/Dockerfile" ;;
    esac
}

SERVICE_IMAGE_TAG() {
    local var
    case "$1" in
        billing-service)         var="${BILLING_SERVICE_IMAGE:-}" ;;
        user-service)            var="${USER_SERVICE_IMAGE:-}" ;;
        consent-command-service) var="${CONSENT_COMMAND_IMAGE:-}" ;;
        consent-query-service)   var="${CONSENT_QUERY_IMAGE:-}" ;;
        dashboard-service)       var="${DASHBOARD_QUERY_IMAGE:-}" ;;
        promotion-service)       var="${PROMOTION_SERVICE_IMAGE:-}" ;;
        audit-service)           var="${AUDIT_SERVICE_IMAGE:-}" ;;
    esac
    echo "${var:-$DEFAULT_TAG}"
}

SERVICE_NEEDS_SECURITY() {
    case "$1" in
        billing-service|user-service|promotion-service|audit-service|consent-command-service|consent-query-service|dashboard-service) return 0 ;;
        *) return 1 ;;
    esac
}

ALL_SERVICES=(billing-service user-service consent-command-service consent-query-service dashboard-service promotion-service audit-service)

if [ $# -eq 0 ]; then
    BUILD_SERVICES=("${ALL_SERVICES[@]}")
    echo -e "${CYAN}[INFO]${NC} Buildando todos: ${BUILD_SERVICES[*]}"
else
    BUILD_SERVICES=("$@")
    echo -e "${CYAN}[INFO]${NC} Buildando: ${BUILD_SERVICES[*]}"
fi

for svc in "${BUILD_SERVICES[@]}"; do
    if [ "$(SERVICE_MVN_DIR "$svc")" = "" ]; then
        echo -e "${RED}[ERRO]${NC} Serviço desconhecido: $svc"
        echo "  Disponíveis: ${ALL_SERVICES[*]}"
        exit 1
    fi
done

NEEDS_SECURITY=false
for svc in "${BUILD_SERVICES[@]}"; do
    if SERVICE_NEEDS_SECURITY "$svc"; then NEEDS_SECURITY=true; break; fi
done

if [ "$NEEDS_SECURITY" = true ]; then
    echo ""
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}>>> Instalando tcc-security-starter...${NC}"
    echo -e "${YELLOW}========================================${NC}"
    (cd tcc-security-starter && mvn clean install -DskipTests)
    echo -e "${GREEN}>>> tcc-security-starter instalado com sucesso.${NC}"
fi

LOG_DIR=$(mktemp -d)
trap 'rm -rf "$LOG_DIR"' EXIT

build_service() {
    local svc="$1"
    local log="$LOG_DIR/$svc.log"

    exec >"$log" 2>&1

    local mvn_dir dockerfile image_tag
    mvn_dir=$(SERVICE_MVN_DIR "$svc")
    dockerfile=$(SERVICE_DOCKERFILE "$svc")
    image_tag=$(SERVICE_IMAGE_TAG "$svc")

    echo "[$(date)] Iniciando build de $svc"
    echo "  Maven dir : $mvn_dir"
    echo "  Dockerfile: $dockerfile"
    echo "  Image tag : $image_tag"
    echo ""

    echo "--- mvn clean package -DskipTests ($svc) ---"
    if ! (cd "$mvn_dir" && mvn clean package -DskipTests); then
        echo "[ERRO] Maven falhou para $svc"
        exit 1
    fi
    echo ""

    echo "--- docker build -t $image_tag ($svc) ---"
    if ! docker build -t "$image_tag" -f "$dockerfile" .; then
        echo "[ERRO] Docker build falhou para $svc"
        exit 1
    fi

    echo ""
    echo "[$(date)] Build de $svc concluído com sucesso"
}

echo ""
echo -e "${YELLOW}>>> Iniciando builds paralelos dos serviços...${NC}"
echo ""

declare -A PIDS
for svc in "${BUILD_SERVICES[@]}"; do
    build_service "$svc" &
    PIDS["$svc"]=$!
    echo -e "${CYAN}[LAUNCH]${NC} $svc (PID $!)"
done

echo ""
echo -e "${YELLOW}>>> Aguardando conclusão dos builds...${NC}"
echo ""

FAILED=false
for svc in "${BUILD_SERVICES[@]}"; do
    pid="${PIDS[$svc]}"
    if wait "$pid"; then
        echo -e "${GREEN}[OK]${NC} $svc concluído com sucesso"
    else
        echo -e "${RED}[FAIL]${NC} $svc falhou (exit code $?)"
        FAILED=true
    fi
done

echo ""

if [ "$FAILED" = true ]; then
    echo -e "${RED}========================================${NC}"
    echo -e "${RED}>>> Build(s) com falha! Logs abaixo:${NC}"
    echo -e "${RED}========================================${NC}"
    for svc in "${BUILD_SERVICES[@]}"; do
        pid="${PIDS[$svc]}"
        if ! wait "$pid" 2>/dev/null; then
            echo ""
            echo -e "${YELLOW}--- Log de $svc ---${NC}"
            cat "$LOG_DIR/$svc.log"
        fi
    done
    exit 1
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}>>> Todos os builds concluídos com sucesso!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

BUILT_IMAGES=()
for svc in "${BUILD_SERVICES[@]}"; do
    img=$(SERVICE_IMAGE_TAG "$svc")
    BUILT_IMAGES+=("$img")
    echo -e "${CYAN}  -${NC} $img"
done
echo ""

FILTER_ARGS=()
for img in "${BUILT_IMAGES[@]}"; do
    FILTER_ARGS+=(--filter "reference=$img")
done
docker images "${FILTER_ARGS[@]}"
