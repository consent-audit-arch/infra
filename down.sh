#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BASE="-f docker-compose.base.yml"
MOD1="-f docker-compose.module1.yml"
MOD2="-f docker-compose.module2.yml"
MOD3="-f docker-compose.module3.yml"
FRONT="-f docker-compose.frontend.yml"
ALL="$BASE $MOD1 $MOD2 $MOD3 $FRONT"

docker compose $ALL down "$@"

# mantém volumes por padrão (dados de consentimento/dashboard). Use:
#   ./down.sh -v  → apaga também os volumes (reset total)
