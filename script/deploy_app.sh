#!/usr/bin/env bash
set -e

REGION="us-east-2"
CLOUDFRONT_DISTRIBUTION_ID="E12JY6O9FF1FV"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
UPDATE_SCRIPT="${ROOT_DIR}/script/update_identity_pool_id.sh"
UPDATE_BUCKET_SCRIPT="${ROOT_DIR}/script/update_bucket_names.sh"

# Obter nome do bucket do app do Terraform (ou usar default)
cd "${TF_DIR}"
APP_BUCKET=$(terraform output -raw app_bucket_name 2>/dev/null || echo "aws-community-app")
cd "${ROOT_DIR}"

echo ">> Usando bucket do app: ${APP_BUCKET}"

# Atualizar IdentityPoolId antes do deploy (se o script existir e o Terraform estiver aplicado)
if [ -f "$UPDATE_SCRIPT" ]; then
  echo ">> Verificando e atualizando IdentityPoolId no app.js..."
  bash "$UPDATE_SCRIPT" || echo "⚠️  Não foi possível atualizar o IdentityPoolId. Continuando com o deploy..."
fi

# Atualizar nome do bucket CPS antes do deploy
if [ -f "$UPDATE_BUCKET_SCRIPT" ]; then
  echo ">> Verificando e atualizando nome do bucket CPS no app.js..."
  bash "$UPDATE_BUCKET_SCRIPT" || echo "⚠️  Não foi possível atualizar o nome do bucket. Continuando com o deploy..."
fi

echo ">> Publicando app para s3://${APP_BUCKET}"
aws s3 sync "${ROOT_DIR}/app" "s3://${APP_BUCKET}/" --delete --region "${REGION}"

echo ">> Invalidando cache do CloudFront"
INVALIDATION_ID=$(aws cloudfront create-invalidation \
  --distribution-id "${CLOUDFRONT_DISTRIBUTION_ID}" \
  --paths "/*" \
  --query 'Invalidation.Id' \
  --output text)

echo ">> Invalidação criada: ${INVALIDATION_ID}"
echo ">> Aguardando propagação (pode levar alguns minutos)..."

aws cloudfront wait invalidation-completed \
  --distribution-id "${CLOUDFRONT_DISTRIBUTION_ID}" \
  --id "${INVALIDATION_ID}" 2>/dev/null || echo ">> Invalidação em progresso (pode levar alguns minutos para completar)"

echo ">> Deploy do app concluído."
