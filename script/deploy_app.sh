#!/usr/bin/env bash
set -e

APP_BUCKET="aws-community-app"
REGION="us-east-2"
CLOUDFRONT_DISTRIBUTION_ID="E12JY6O9FF1FV"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
