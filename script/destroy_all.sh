#!/usr/bin/env bash
# Destrói toda a infraestrutura gerenciada pelo Terraform (S3, Lambda, EventBridge, Cognito, CloudFront, Route53, IAM).
# Uso: bash script/destroy_all.sh
#      AUTO_APPROVE=1 bash script/destroy_all.sh   # sem confirmação (ex.: CI)
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"

echo ">> Este script irá DESTRUIR TODA a infraestrutura do projeto:"
echo ">>   - Buckets S3 (app + CPS: vídeos, transcrições, resumos)"
echo ">>   - Lambdas (Transcribe + Bedrock)"
echo ">>   - Regras EventBridge"
echo ">>   - Cognito Identity Pool e roles IAM"
echo ">>   - Distribuição CloudFront"
echo ">>   - Registro Route53 do domínio"
echo ""

if [ "${AUTO_APPROVE}" != "1" ]; then
  read -p ">> Digite 'sim' para confirmar a destruição total: " confirm
  if [ "$confirm" != "sim" ]; then
    echo ">> Operação cancelada."
    exit 1
  fi
fi

cd "${TF_DIR}"

if [ ! -d .terraform ]; then
  echo ">> Terraform não inicializado. Rodando terraform init..."
  terraform init
fi

echo ">> Executando terraform destroy..."
terraform destroy ${AUTO_APPROVE:+ -auto-approve}

echo ""
echo ">> Destruição concluída. Recursos criados fora do Terraform (ex.: certificado ACM, usuário IAM do setup-iam-prereqs) não foram removidos."
