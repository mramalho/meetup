#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
SCRIPT_DIR="${ROOT_DIR}/script"
CONFIG_DIR="${ROOT_DIR}/config"

# Carregar config (BUCKET_NAME, AWS_REGION) para backend e setup
if [ -f "${CONFIG_DIR}/config.env" ]; then
  set -a
  source "${CONFIG_DIR}/config.env"
  set +a
fi
BUCKET_NAME="${BUCKET_NAME:?Defina BUCKET_NAME em config/config.env}"
AWS_REGION="${AWS_REGION:-us-east-2}"

# Garantir que o bucket do backend existe
if [ -f "${SCRIPT_DIR}/setup-terraform-backend.sh" ]; then
  bash "${SCRIPT_DIR}/setup-terraform-backend.sh" 2>/dev/null || true
fi

cd "${TF_DIR}"

echo ">> Rodando terraform init (backend: s3://${BUCKET_NAME}/tfvars/meetup)"
terraform init -reconfigure \
  -backend-config="bucket=${BUCKET_NAME}" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="key=tfvars/meetup/terraform.tfstate"

echo ">> Rodando terraform apply"
terraform apply

echo ">> Atualizando app.js (IdentityPoolId e bucket CPS)"
UPDATE_APP_CONFIG="${ROOT_DIR}/script/update_app_config.sh"
if [ -f "$UPDATE_APP_CONFIG" ]; then
  bash "$UPDATE_APP_CONFIG"
else
  echo "⚠️  Atualize manualmente IdentityPoolId e videoBucket no app/app.js com os outputs do Terraform"
fi
