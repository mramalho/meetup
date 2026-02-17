#!/usr/bin/env bash
# Destrói toda a infraestrutura: Terraform, certificado ACM e usuário IAM (se criados pelo create-all.sh).
# Uso: bash script/destroy-all.sh
#      AUTO_APPROVE=1 bash script/destroy-all.sh   # sem confirmação (ex.: CI)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
STATE_FILE="${SCRIPT_DIR}/.create-all-state"

echo ">> Este script irá DESTRUIR TODA a infraestrutura do projeto:"
echo ">>   - Buckets S3 (app + CPS: vídeos, transcrições, resumos)"
echo ">>   - Lambdas (Transcribe + Bedrock)"
echo ">>   - Regras EventBridge"
echo ">>   - Cognito Identity Pool e roles IAM"
echo ">>   - Distribuição CloudFront"
echo ">>   - Registro Route53 do domínio"
echo ">>   - Certificado ACM (se criado pelo create-all.sh)"
echo ">>   - Usuário IAM de deploy (se criado pelo create-all.sh)"
echo ""

if [ "${AUTO_APPROVE}" != "1" ]; then
  read -p ">> Digite 'sim' para confirmar a destruição total: " confirm
  if [ "$confirm" != "sim" ]; then
    echo ">> Operação cancelada."
    exit 1
  fi
fi

# --- 1. Terraform destroy ---
echo ""
echo ">> [1/3] Destruindo recursos Terraform..."
cd "${TF_DIR}"

if [ ! -d .terraform ]; then
  echo ">> Terraform não inicializado. Rodando terraform init..."
  terraform init
fi

terraform destroy ${AUTO_APPROVE:+ -auto-approve}

# --- 2. Deletar certificado ACM (se foi criado pelo create-all) ---
echo ""
echo ">> [2/3] Verificando certificado ACM..."
# Só remove ACM se foi criado pelo create-all (está no state)
ACM_ARN=""
if [ -f "${STATE_FILE}" ]; then
  ACM_ARN=$(grep "^ACM_CERTIFICATE_ARN=" "${STATE_FILE}" 2>/dev/null | cut -d= -f2-)
fi

if [ -n "$ACM_ARN" ]; then
  echo ">> Deletando certificado ACM: ${ACM_ARN}"
  aws acm delete-certificate --certificate-arn "$ACM_ARN" --region us-east-1 2>/dev/null && echo "   Certificado deletado." || echo "   (Certificado já removido ou sem permissão)"
else
  echo ">> Nenhum certificado ACM encontrado para remover."
fi

# --- 3. Deletar usuário IAM (se foi criado pelo create-all) ---
echo ""
echo ">> [3/3] Verificando usuário IAM..."
IAM_USER_CREATED=""
DEPLOY_USER_NAME=""
if [ -f "${STATE_FILE}" ]; then
  IAM_USER_CREATED=$(grep "^IAM_USER_CREATED=" "${STATE_FILE}" 2>/dev/null | cut -d= -f2)
  DEPLOY_USER_NAME=$(grep "^DEPLOY_USER_NAME=" "${STATE_FILE}" 2>/dev/null | cut -d= -f2)
fi

if [ "$IAM_USER_CREATED" = "1" ] && [ -n "$DEPLOY_USER_NAME" ]; then
  echo ">> Removendo usuário IAM: ${DEPLOY_USER_NAME}"
  # Detach policies
  for policy in $(aws iam list-attached-user-policies --user-name "$DEPLOY_USER_NAME" --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null); do
    [ -n "$policy" ] && aws iam detach-user-policy --user-name "$DEPLOY_USER_NAME" --policy-arn "$policy" 2>/dev/null || true
  done
  # Delete access keys
  for key in $(aws iam list-access-keys --user-name "$DEPLOY_USER_NAME" --query 'AccessKeyMetadata[*].AccessKeyId' --output text 2>/dev/null); do
    [ -n "$key" ] && aws iam delete-access-key --user-name "$DEPLOY_USER_NAME" --access-key-id "$key" 2>/dev/null || true
  done
  aws iam delete-user --user-name "$DEPLOY_USER_NAME" 2>/dev/null && echo "   Usuário deletado." || echo "   (Usuário já removido ou sem permissão)"
else
  echo ">> Nenhum usuário IAM criado pelo create-all para remover."
fi

# Limpar state
rm -f "${STATE_FILE}"

echo ""
echo ">> Destruição concluída."
