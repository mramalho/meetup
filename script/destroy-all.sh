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
echo ">>   - Bucket S3 meetup-bosch (app/, model/, tfvars/)"
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
echo ">> [1/4] Destruindo recursos Terraform..."
cd "${TF_DIR}"

if [ ! -d .terraform ]; then
  echo ">> Terraform não inicializado. Rodando terraform init..."
  terraform init
fi

terraform destroy ${AUTO_APPROVE:+ -auto-approve}

# --- 2. Esvaziar e deletar bucket meetup-bosch (Terraform usa data source, não remove o bucket) ---
echo ""
echo ">> [2/4] Esvaziando e removendo bucket meetup-bosch..."
BUCKET="meetup-bosch"
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo ">> Esvaziando bucket ${BUCKET}..."
  aws s3 rm "s3://${BUCKET}/" --recursive 2>/dev/null || true
  echo ">> Deletando bucket ${BUCKET}..."
  aws s3 rb "s3://${BUCKET}" --force 2>/dev/null && echo "   Bucket deletado." || echo "   (Bucket já removido ou erro)"
else
  echo ">> Bucket ${BUCKET} não existe ou já foi removido."
fi

# Remover buckets antigos (migração: mramalho-tfvars, aws-community-app, aws-community-cps)
for old_bucket in mramalho-tfvars aws-community-app aws-community-cps; do
  if aws s3api head-bucket --bucket "$old_bucket" 2>/dev/null; then
    echo ">> Removendo bucket legado ${old_bucket}..."
    aws s3 rm "s3://${old_bucket}/" --recursive 2>/dev/null || true
    aws s3 rb "s3://${old_bucket}" --force 2>/dev/null && echo "   ${old_bucket} deletado." || echo "   (Erro ao remover ${old_bucket})"
  fi
done

# --- 3. Deletar certificado ACM (se foi criado pelo create-all) ---
echo ""
echo ">> [3/4] Verificando certificado ACM..."
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

# --- 4. Deletar usuário IAM (se foi criado pelo create-all) ---
echo ""
echo ">> [4/4] Verificando usuário IAM..."
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
