#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"

# Obter nome do bucket CPS do Terraform (ou usar default)
cd "${TF_DIR}"
CPS_BUCKET=$(terraform output -raw cps_bucket_name 2>/dev/null || echo "aws-community-cps")
cd "${ROOT_DIR}"

echo ">> Usando bucket CPS: ${CPS_BUCKET}"
REGION="us-east-2"

echo ">> ATENÇÃO: Este script irá apagar TODOS os arquivos de:"
echo ">>   - s3://${CPS_BUCKET}/video/"
echo ">>   - s3://${CPS_BUCKET}/transcribe/"
echo ""
read -p ">> Deseja continuar? (digite 'sim' para confirmar): " confirm

if [ "$confirm" != "sim" ]; then
    echo ">> Operação cancelada."
    exit 1
fi

echo ">> Limpando arquivos do bucket s3://${CPS_BUCKET}/video/"
aws s3 rm "s3://${CPS_BUCKET}/video/" --recursive --region "${REGION}"

echo ">> Limpando arquivos do bucket s3://${CPS_BUCKET}/transcribe/"
aws s3 rm "s3://${CPS_BUCKET}/transcribe/" --recursive --region "${REGION}"

echo ">> Limpeza concluída."

