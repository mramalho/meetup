#!/usr/bin/env bash
# Cria um usuário IAM para deploy (opcional) e exibe políticas mínimas.
# Uso: DEPLOY_USER_NAME=aws-meetup-deploy bash script/setup-iam-prereqs.sh
# Requer: AWS CLI configurado com permissões para criar usuário e anexar políticas.
set -e

DEPLOY_USER_NAME="${DEPLOY_USER_NAME:-aws-meetup-deploy}"

echo ">> Criando usuário IAM: ${DEPLOY_USER_NAME}"
aws iam create-user --user-name "$DEPLOY_USER_NAME" 2>/dev/null || echo "   (usuário já existe)"

echo ">> Anexando política gerenciada PowerUserAccess (acesso amplo, exceto IAM usuários/grupos)"
aws iam attach-user-policy \
  --user-name "$DEPLOY_USER_NAME" \
  --policy-arn "arn:aws:iam::aws:policy/PowerUserAccess" 2>/dev/null || echo "   (política já anexada)"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo ""
echo ">> Usuário criado: ${DEPLOY_USER_NAME} (conta ${ACCOUNT_ID})"
echo ">> Para usar com AWS CLI / Terraform, crie uma Access Key no console:"
echo "   AWS Console → IAM → Users → ${DEPLOY_USER_NAME} → Security credentials → Create access key"
echo "   Depois: aws configure --profile meetup-deploy"
echo ">> Política anexada: PowerUserAccess (permite criar S3, Lambda, CloudFront, Cognito, etc.; não permite gerenciar usuários IAM)."
