#!/usr/bin/env bash
# Gera app/config.json com identity_pool_id, region e cps_bucket_name a partir dos outputs do Terraform.
# O app.js carrega config.json em runtime - nenhum dado sensível fica no código-fonte.
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
CONFIG_JSON="${ROOT_DIR}/app/config.json"

cd "${TF_DIR}"
IDENTITY_POOL_ID=$(terraform output -raw identity_pool_id 2>/dev/null || echo "")
CPS_BUCKET_NAME=$(terraform output -raw cps_bucket_name 2>/dev/null || echo "")
AWS_REGION=$(terraform output -raw aws_region 2>/dev/null || echo "")
cd "${ROOT_DIR}"

if [ -z "$IDENTITY_POOL_ID" ] && [ -z "$CPS_BUCKET_NAME" ]; then
  echo "⚠️  Nenhum output do Terraform encontrado. Execute 'terraform apply' antes."
  exit 0
fi

# Resolver região (terraform output aws_region pode não existir)
if [ -z "$AWS_REGION" ] || [[ "$AWS_REGION" == *"aws_region"* ]]; then
  AWS_REGION="us-east-2"
fi

mkdir -p "$(dirname "$CONFIG_JSON")"
cat > "$CONFIG_JSON" << EOF
{
  "identityPoolId": "${IDENTITY_POOL_ID}",
  "region": "${AWS_REGION}",
  "videoBucket": "${CPS_BUCKET_NAME}"
}
EOF

echo "✅ config.json gerado com identityPoolId, region e videoBucket."
