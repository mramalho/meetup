#!/usr/bin/env bash
set -e

# Script para atualizar automaticamente o nome do bucket CPS no app.js
# usando o valor do output do Terraform

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
APP_JS="${ROOT_DIR}/app/app.js"

cd "${TF_DIR}"

echo ">> Obtendo nome do bucket CPS do Terraform..."
CPS_BUCKET_NAME=$(terraform output -raw cps_bucket_name 2>/dev/null || echo "")

if [ -z "$CPS_BUCKET_NAME" ]; then
  echo "⚠️  Aviso: Não foi possível obter o cps_bucket_name do Terraform."
  echo "   Certifique-se de que o Terraform foi aplicado com sucesso."
  echo "   O script continuará sem atualizar o app.js."
  exit 0
fi

echo ">> Nome do bucket CPS encontrado: ${CPS_BUCKET_NAME}"

if [ ! -f "$APP_JS" ]; then
  echo "❌ Erro: Arquivo app.js não encontrado em ${APP_JS}"
  exit 1
fi

# Backup do arquivo original
BACKUP_FILE="${APP_JS}.backup"
cp "$APP_JS" "$BACKUP_FILE"
echo ">> Backup criado: ${BACKUP_FILE}"

# Atualizar o nome do bucket no app.js
# Procura por padrão: const videoBucket = "nome-do-bucket";
if [[ "$OSTYPE" == "darwin"* ]]; then
  # macOS usa BSD sed
  sed -i '' "s/const videoBucket = \"[^\"]*\"/const videoBucket = \"${CPS_BUCKET_NAME}\"/" "$APP_JS"
else
  # Linux usa GNU sed
  sed -i "s/const videoBucket = \"[^\"]*\"/const videoBucket = \"${CPS_BUCKET_NAME}\"/" "$APP_JS"
fi

echo "✅ Nome do bucket CPS atualizado no app.js"
echo "   Valor anterior salvo em: ${BACKUP_FILE}"

