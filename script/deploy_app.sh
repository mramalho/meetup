#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
UPDATE_APP_CONFIG="${ROOT_DIR}/script/update_app_config.sh"

# Obter do Terraform (exige terraform apply já executado)
cd "${TF_DIR}"
APP_BUCKET=$(terraform output -raw app_bucket_name 2>/dev/null || echo "aws-community-app")
CLOUDFRONT_DISTRIBUTION_ID=$(terraform output -raw cloudfront_distribution_id 2>/dev/null || echo "")
cd "${ROOT_DIR}"

REGION="${AWS_REGION:-us-east-2}"

if [ -z "$CLOUDFRONT_DISTRIBUTION_ID" ]; then
  echo "⚠️  cloudfront_distribution_id não encontrado no Terraform. Execute 'terraform apply' antes do deploy."
  echo "   Para apenas publicar no S3 (sem invalidação), defina SKIP_CLOUDFRONT_INVALIDATION=1"
  if [ "${SKIP_CLOUDFRONT_INVALIDATION}" != "1" ]; then
    exit 1
  fi
fi

echo ">> Usando bucket do app: ${APP_BUCKET}"

# Gerar config.json (identityPoolId, region, videoBucket) a partir do Terraform
if [ -f "$UPDATE_APP_CONFIG" ]; then
  echo ">> Atualizando config do app (IdentityPoolId, bucket)..."
  bash "$UPDATE_APP_CONFIG" || true
fi

echo ">> Publicando app para s3://${APP_BUCKET}"
# Exclui config.json.example (template) - apenas config.json (gerado) deve ser publicado
aws s3 sync "${ROOT_DIR}/app" "s3://${APP_BUCKET}/" --delete --exclude "config.json.example" --region "${REGION}"

if [ -n "$CLOUDFRONT_DISTRIBUTION_ID" ] && [ "${SKIP_CLOUDFRONT_INVALIDATION}" != "1" ]; then
  echo ">> Invalidando cache do CloudFront (${CLOUDFRONT_DISTRIBUTION_ID})"
  INVALIDATION_ID=$(aws cloudfront create-invalidation \
    --distribution-id "${CLOUDFRONT_DISTRIBUTION_ID}" \
    --paths "/*" \
    --query 'Invalidation.Id' \
    --output text)
  echo ">> Invalidação criada: ${INVALIDATION_ID}"
  aws cloudfront wait invalidation-completed \
    --distribution-id "${CLOUDFRONT_DISTRIBUTION_ID}" \
    --id "${INVALIDATION_ID}" 2>/dev/null || echo ">> Invalidação em progresso."
fi

echo ">> Deploy do app concluído."
