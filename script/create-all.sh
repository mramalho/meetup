#!/usr/bin/env bash
# Cria toda a infraestrutura do zero: ACM, IAM (opcional), Terraform e deploy do app.
# Uso:
#   1. cp config/config.env.example config/config.env
#   2. Edite config/config.env com seus valores
#   3. bash script/create-all.sh
#
# O script descobre HOSTED_ZONE_ID automaticamente se estiver vazio e o domínio existir no Route53.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
STATE_FILE="${SCRIPT_DIR}/.create-all-state"

echo "=========================================="
echo ">> create-all.sh - Criação completa"
echo "=========================================="

# Carregar config
CONFIG_DIR="${ROOT_DIR}/config"
if [ -f "${CONFIG_DIR}/config.env" ]; then
  echo ">> Carregando config.env..."
  set -a
  source "${CONFIG_DIR}/config.env"
  set +a
else
  echo "❌ Arquivo config.env não encontrado."
  echo "   Copie o exemplo: cp config/config.env.example config/config.env"
  echo "   Depois edite config/config.env com seus valores."
  exit 1
fi

DOMAIN_NAME="${DOMAIN_NAME:?Defina DOMAIN_NAME em config/config.env}"
CREATE_ACM="${CREATE_ACM:-1}"
CREATE_IAM_USER="${CREATE_IAM_USER:-0}"
DEPLOY_USER_NAME="${DEPLOY_USER_NAME:-aws-meetup-deploy}"
AWS_REGION="${AWS_REGION:-us-east-2}"
BUCKET_NAME="${BUCKET_NAME:-your-bucket-name}"
BEDROCK_REGION="${BEDROCK_REGION:-us-east-2}"
BEDROCK_MODEL_ID="${BEDROCK_MODEL_ID:-anthropic.claude-haiku-4-5-20251001-v1:0}"
BEDROCK_INFERENCE_PROFILE="${BEDROCK_INFERENCE_PROFILE:-}"
BEDROCK_LOGS_RETENTION_DAYS="${BEDROCK_LOGS_RETENTION_DAYS:-30}"
CORS_EXTRA_ORIGINS="${CORS_EXTRA_ORIGINS:-}"
OBSERVABILITY_DEBUG="${OBSERVABILITY_DEBUG:-0}"
OBSERVABILITY_TRACE="${OBSERVABILITY_TRACE:-0}"

# Limpar state anterior para nova execução
rm -f "${STATE_FILE}"

# --- Descobrir HOSTED_ZONE_ID se vazio ---
if [ -z "${HOSTED_ZONE_ID}" ]; then
  echo ">> HOSTED_ZONE_ID não definido. Tentando descobrir automaticamente..."
  DOMAIN_DOTTED="${DOMAIN_NAME}."
  ZONES=$(aws route53 list-hosted-zones --query "HostedZones[*].{Name:Name,Id:Id}" --output json 2>/dev/null)
  HOSTED_ZONE_ID=$(echo "$ZONES" | python3 -c "
import json, sys
data = json.load(sys.stdin)
domain = '${DOMAIN_DOTTED}'.rstrip('.')
best = None
longest = 0
for z in data:
    name = z['Name'].rstrip('.')
    if domain == name or domain.endswith('.' + name):
        if len(name) > longest:
            longest = len(name)
            best = z['Id'].replace('/hostedzone/', '')
print(best or '')
" 2>/dev/null || echo "")
  if [ -n "${HOSTED_ZONE_ID}" ]; then
    echo ">> Hosted zone encontrada: ${HOSTED_ZONE_ID}"
  fi
  if [ -z "${HOSTED_ZONE_ID}" ]; then
    echo "⚠️  Não foi possível descobrir HOSTED_ZONE_ID automaticamente."
    echo "   Liste suas zonas: aws route53 list-hosted-zones --query \"HostedZones[*].{Name:Name,Id:Id}\" --output table"
    echo "   Adicione HOSTED_ZONE_ID em config/config.env (apenas a parte após /hostedzone/, ex: Z0ABC123)"
    echo ""
    echo "   O Terraform precisa do hosted_zone_id para criar o registro Route53. Não é possível continuar sem ele."
    exit 1
  fi
fi

# --- 1. Certificado ACM ---
if [ "${CREATE_ACM}" = "1" ]; then
  echo ""
  echo ">> [1/6] Criando certificado ACM..."
  export DOMAIN_NAME
  export HOSTED_ZONE_ID
  CERT_OUTPUT=$(bash "${SCRIPT_DIR}/setup-acm-certificate.sh" 2>&1)
  ACM_CERTIFICATE_ARN=$(echo "$CERT_OUTPUT" | grep -oE 'arn:aws:acm:us-east-1:[0-9]+:certificate/[a-f0-9-]+' | tail -1)
  if [ -z "$ACM_CERTIFICATE_ARN" ]; then
    echo "❌ Não foi possível obter o ARN do certificado."
    exit 1
  fi
  echo "   ACM_CERTIFICATE_ARN=$ACM_CERTIFICATE_ARN" >> "${STATE_FILE}"
else
  ACM_CERTIFICATE_ARN="${ACM_CERTIFICATE_ARN:?Defina ACM_CERTIFICATE_ARN em config/config.env quando CREATE_ACM=0}"
fi

# --- 2. Usuário IAM (opcional) ---
if [ "${CREATE_IAM_USER}" = "1" ]; then
  echo ""
  echo ">> [2/6] Criando usuário IAM..."
  export DEPLOY_USER_NAME
  bash "${SCRIPT_DIR}/setup-iam-prereqs.sh" || true
  echo "IAM_USER_CREATED=1" >> "${STATE_FILE}"
  echo "DEPLOY_USER_NAME=${DEPLOY_USER_NAME}" >> "${STATE_FILE}"
else
  echo ""
  echo ">> [2/6] Pulando criação de usuário IAM (CREATE_IAM_USER=0)"
fi

# --- 3. Gerar terraform.tfvars ---
echo ""
echo ">> [3/6] Gerando terraform.tfvars..."
cat > "${TF_DIR}/terraform.tfvars" << EOF
aws_region         = "${AWS_REGION}"
bucket_name        = "${BUCKET_NAME}"
domain_name        = "${DOMAIN_NAME}"
acm_certificate_arn = "${ACM_CERTIFICATE_ARN}"
hosted_zone_id     = "${HOSTED_ZONE_ID}"
cors_extra_origins = "${CORS_EXTRA_ORIGINS:-}"

bedrock_region            = "${BEDROCK_REGION}"
bedrock_model_id          = "${BEDROCK_MODEL_ID}"
bedrock_inference_profile = "${BEDROCK_INFERENCE_PROFILE}"
bedrock_logs_retention_days = ${BEDROCK_LOGS_RETENTION_DAYS:-30}

observability_debug = "${OBSERVABILITY_DEBUG}"
observability_trace = "${OBSERVABILITY_TRACE}"
EOF

# --- 4. Backend Terraform (bucket S3 para state) ---
echo ""
echo ">> [4/7] Verificando backend Terraform (s3://${BUCKET_NAME}/tfvars/meetup)..."
bash "${SCRIPT_DIR}/setup-terraform-backend.sh" 2>/dev/null || true

# --- 5. Build das Lambdas ---
echo ""
echo ">> [5/7] Build das Lambdas..."
bash "${SCRIPT_DIR}/build_lambdas.sh"

# --- 6. Terraform apply ---
echo ""
echo ">> [6/7] Deploy da infraestrutura (Terraform)..."
bash "${SCRIPT_DIR}/terraform_deploy.sh"

# --- 7. Deploy do app ---
echo ""
echo ">> [7/7] Deploy do frontend..."
bash "${SCRIPT_DIR}/deploy_app.sh"

echo ""
echo "=========================================="
echo ">> ✅ Criação concluída!"
echo ">> Acesse: https://${DOMAIN_NAME}"
echo "=========================================="
