#!/usr/bin/env bash
set -e

# Script para atualizar automaticamente o IdentityPoolId no app.js
# usando o valor do output do Terraform

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
APP_JS="${ROOT_DIR}/app/app.js"

cd "${TF_DIR}"

echo ">> Obtendo IdentityPoolId do Terraform..."
IDENTITY_POOL_ID=$(terraform output -raw identity_pool_id 2>/dev/null || echo "")

if [ -z "$IDENTITY_POOL_ID" ]; then
  echo "⚠️  Aviso: Não foi possível obter o identity_pool_id do Terraform."
  echo "   Certifique-se de que o Terraform foi aplicado com sucesso."
  echo "   O script continuará sem atualizar o app.js."
  exit 0
fi

echo ">> IdentityPoolId encontrado: ${IDENTITY_POOL_ID}"

if [ ! -f "$APP_JS" ]; then
  echo "❌ Erro: Arquivo app.js não encontrado em ${APP_JS}"
  exit 1
fi

# Backup do arquivo original
BACKUP_FILE="${APP_JS}.backup"
cp "$APP_JS" "$BACKUP_FILE"
echo ">> Backup criado: ${BACKUP_FILE}"

# Atualizar o IdentityPoolId no app.js
# Procura por padrão: IdentityPoolId: "us-east-2:xxxxx" ou IdentityPoolId: "xxxxx"
if [[ "$OSTYPE" == "darwin"* ]]; then
  # macOS usa BSD sed
  sed -i '' "s/IdentityPoolId: \"[^\"]*\"/IdentityPoolId: \"${IDENTITY_POOL_ID}\"/" "$APP_JS"
else
  # Linux usa GNU sed
  sed -i "s/IdentityPoolId: \"[^\"]*\"/IdentityPoolId: \"${IDENTITY_POOL_ID}\"/" "$APP_JS"
fi

echo "✅ IdentityPoolId atualizado no app.js"
echo "   Valor anterior salvo em: ${BACKUP_FILE}"

