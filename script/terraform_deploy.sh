#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
SCRIPT_DIR="${ROOT_DIR}/script"

# Garantir que o bucket do backend existe (s3://mramalho-tfvars/meetup)
if [ -f "${SCRIPT_DIR}/setup-terraform-backend.sh" ]; then
  bash "${SCRIPT_DIR}/setup-terraform-backend.sh" 2>/dev/null || true
fi

cd "${TF_DIR}"

echo ">> Rodando terraform init"
terraform init

echo ">> Rodando terraform apply"
terraform apply

echo ">> Atualizando app.js (IdentityPoolId e bucket CPS)"
UPDATE_APP_CONFIG="${ROOT_DIR}/script/update_app_config.sh"
if [ -f "$UPDATE_APP_CONFIG" ]; then
  bash "$UPDATE_APP_CONFIG"
else
  echo "⚠️  Atualize manualmente IdentityPoolId e videoBucket no app/app.js com os outputs do Terraform"
fi
