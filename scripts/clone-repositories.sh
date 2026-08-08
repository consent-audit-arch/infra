#!/usr/bin/env bash
set -euo pipefail
workspace_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for mapping in \
  consent-command-service:consent-command-service \
  consent-query-service:consent-query-service \
  dashboard-service:dashboard-service \
  user-service:user-service \
  billing-service:billing-service \
  promotions-service:promotion-service \
  audit-service:audit-service \
  tcc-security-starter:tcc-security-starter \
  consent-frontend:frontend; do
  remote_repo="${mapping%%:*}"
  local_repo="${mapping##*:}"
  if [ -e "$workspace_dir/$local_repo" ]; then
    printf 'Preservando diretório existente: %s\n' "$local_repo"
  else
    git clone "git@github.com:consent-audit-arch/$remote_repo.git" "$workspace_dir/$local_repo"
  fi
done
