#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
UPDATE_SCRIPT="${ROOT_DIR}/script/update_identity_pool_id.sh"

cd "${TF_DIR}"

echo ">> Rodando terraform init"
terraform init

echo ">> Rodando terraform apply"
terraform apply

echo ">> Atualizando IdentityPoolId no app.js"
if [ -f "$UPDATE_SCRIPT" ]; then
  bash "$UPDATE_SCRIPT"
else
  echo "⚠️  Script de atualização não encontrado. Atualize manualmente o IdentityPoolId no app.js"
fi

echo ">> Atualizando nome do bucket CPS no app.js"
UPDATE_BUCKET_SCRIPT="${ROOT_DIR}/script/update_bucket_names.sh"
if [ -f "$UPDATE_BUCKET_SCRIPT" ]; then
  bash "$UPDATE_BUCKET_SCRIPT"
else
  echo "⚠️  Script de atualização não encontrado. Atualize manualmente o nome do bucket no app.js"
fi
