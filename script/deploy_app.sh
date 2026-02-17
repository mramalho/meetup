#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
UPDATE_APP_CONFIG="${ROOT_DIR}/script/update_app_config.sh"

# Obter do Terraform (exige terraform apply já executado)
cd "${TF_DIR}"
BUCKET_NAME=$(terraform output -raw bucket_name 2>/dev/null || echo "meetup-bosch")
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

echo ">> Usando bucket: ${BUCKET_NAME} (prefixo app/)"

# Gerar config/config.json (identityPoolId, region, videoBucket) a partir do Terraform
if [ -f "$UPDATE_APP_CONFIG" ]; then
  echo ">> Atualizando config do app (IdentityPoolId, bucket)..."
  bash "$UPDATE_APP_CONFIG" || true
fi

# Copiar config.json para app/ (o app carrega config.json em runtime do mesmo diretório)
if [ -f "${ROOT_DIR}/config/config.json" ]; then
  cp "${ROOT_DIR}/config/config.json" "${ROOT_DIR}/app/config.json"
fi

echo ">> Publicando app para s3://${BUCKET_NAME}/app/"
aws s3 sync "${ROOT_DIR}/app" "s3://${BUCKET_NAME}/app/" --delete --exclude "config.json.example" --region "${REGION}"

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
