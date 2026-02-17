#!/usr/bin/env bash
# Gera config/config.json com identity_pool_id, region e bucket_name a partir dos outputs do Terraform.
# O app.js carrega config.json em runtime (copiado para app/ no deploy).
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
CONFIG_DIR="${ROOT_DIR}/config"
CONFIG_JSON="${CONFIG_DIR}/config.json"

cd "${TF_DIR}"
IDENTITY_POOL_ID=$(terraform output -raw identity_pool_id 2>/dev/null || echo "")
BUCKET_NAME=$(terraform output -raw bucket_name 2>/dev/null || echo "")
AWS_REGION=$(terraform output -raw aws_region 2>/dev/null || echo "")
cd "${ROOT_DIR}"

if [ -z "$IDENTITY_POOL_ID" ] && [ -z "$BUCKET_NAME" ]; then
  echo "⚠️  Nenhum output do Terraform encontrado. Execute 'terraform apply' antes."
  exit 0
fi

# Resolver região (terraform output aws_region pode não existir)
if [ -z "$AWS_REGION" ] || [[ "$AWS_REGION" == *"aws_region"* ]]; then
  AWS_REGION="us-east-2"
fi

mkdir -p "${CONFIG_DIR}"
cat > "$CONFIG_JSON" << EOF
{
  "identityPoolId": "${IDENTITY_POOL_ID}",
  "region": "${AWS_REGION}",
  "videoBucket": "${BUCKET_NAME}"
}
EOF

echo "✅ config.json gerado com identityPoolId, region e videoBucket."
