#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"

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
