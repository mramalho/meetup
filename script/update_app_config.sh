#!/usr/bin/env bash
# Atualiza app/app.js com identity_pool_id e cps_bucket_name a partir dos outputs do Terraform.
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
APP_JS="${ROOT_DIR}/app/app.js"

cd "${TF_DIR}"
IDENTITY_POOL_ID=$(terraform output -raw identity_pool_id 2>/dev/null || echo "")
CPS_BUCKET_NAME=$(terraform output -raw cps_bucket_name 2>/dev/null || echo "")
cd "${ROOT_DIR}"

if [ -z "$IDENTITY_POOL_ID" ] && [ -z "$CPS_BUCKET_NAME" ]; then
  echo "⚠️  Nenhum output do Terraform encontrado. Execute 'terraform apply' antes."
  exit 0
fi

[ ! -f "$APP_JS" ] && echo "❌ app.js não encontrado: $APP_JS" && exit 1

sed_inplace() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

UPDATED=0
if [ -n "$IDENTITY_POOL_ID" ]; then
  sed_inplace "s/IdentityPoolId: \"[^\"]*\"/IdentityPoolId: \"${IDENTITY_POOL_ID}\"/" "$APP_JS"
  echo "✅ IdentityPoolId atualizado."
  UPDATED=1
fi
if [ -n "$CPS_BUCKET_NAME" ]; then
  sed_inplace "s/const videoBucket = \"[^\"]*\"/const videoBucket = \"${CPS_BUCKET_NAME}\"/" "$APP_JS"
  echo "✅ videoBucket (CPS) atualizado."
  UPDATED=1
fi

[ "$UPDATED" = "1" ] && echo ">> app.js atualizado com valores do Terraform."
