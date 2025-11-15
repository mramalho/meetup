#!/usr/bin/env bash
set -e

CPS_BUCKET="aws-community-cps"
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

