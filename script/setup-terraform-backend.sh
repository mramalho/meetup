#!/usr/bin/env bash
# Cria o bucket S3 para o backend do Terraform (state remoto).
# Bucket: meetup-bosch
# Path: tfvars/meetup/terraform.tfstate
#
# Segurança (alinhado com as práticas do projeto):
# - Block Public Access (nenhum acesso público)
# - Criptografia SSE-S3 (AES256)
# - Versionamento (recuperação de state)
#
# Execute antes do primeiro terraform init se o bucket ainda não existir.
# Uso: bash script/setup-terraform-backend.sh
set -e

BUCKET="meetup-bosch"
REGION="${AWS_REGION:-us-east-2}"

echo ">> Verificando bucket ${BUCKET}..."
BUCKET_EXISTS=false
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  BUCKET_EXISTS=true
  echo ">> Bucket ${BUCKET} já existe. Aplicando configurações de segurança..."
fi

if [ "$BUCKET_EXISTS" = false ]; then
  echo ">> Criando bucket ${BUCKET} em ${REGION}..."
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket \
      --bucket "$BUCKET" \
      --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
fi

echo ">> Bloqueando acesso público (segurança)..."
aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

echo ">> Habilitando versionamento (recuperação de state)..."
aws s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

echo ">> Habilitando criptografia SSE-S3 (AES256)..."
aws s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"},
      "BucketKeyEnabled": true
    }]
  }'

echo ""
echo ">> Backend configurado: s3://${BUCKET}/tfvars/meetup/terraform.tfstate"
echo ">> Execute 'terraform init' na pasta terraform/."
