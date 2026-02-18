#!/usr/bin/env bash
# Cria certificado SSL/TLS no ACM (us-east-1) para uso no CloudFront.
# Uso: DOMAIN_NAME=example.com [HOSTED_ZONE_ID=Z...] bash script/setup-acm-certificate.sh
set -e

DOMAIN_NAME="${DOMAIN_NAME:?Defina DOMAIN_NAME (ex: example.com)}"
REGION_ACM="us-east-1"

echo ">> Solicitando certificado ACM para ${DOMAIN_NAME} em ${REGION_ACM}..."
CERT_ARN=$(aws acm request-certificate \
  --domain-name "$DOMAIN_NAME" \
  --validation-method DNS \
  --region "$REGION_ACM" \
  --query 'CertificateArn' \
  --output text)

echo ">> Certificado solicitado: ${CERT_ARN}"

if [ -n "${HOSTED_ZONE_ID}" ]; then
  echo ">> Aguardando registro de validação ficar disponível..."
  sleep 10
  RECORD_NAME=$(aws acm describe-certificate --certificate-arn "$CERT_ARN" --region "$REGION_ACM" \
    --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Name' --output text 2>/dev/null || echo "")
  RECORD_VALUE=$(aws acm describe-certificate --certificate-arn "$CERT_ARN" --region "$REGION_ACM" \
    --query 'Certificate.DomainValidationOptions[0].ResourceRecord.Value' --output text 2>/dev/null || echo "")

  if [ -n "$RECORD_NAME" ] && [ -n "$RECORD_VALUE" ] && [ "$RECORD_NAME" != "None" ]; then
    echo ">> Criando registro CNAME na hosted zone ${HOSTED_ZONE_ID}..."
    aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --change-batch "{
      \"Changes\": [{
        \"Action\": \"UPSERT\",
        \"ResourceRecordSet\": {
          \"Name\": \"${RECORD_NAME}\",
          \"Type\": \"CNAME\",
          \"TTL\": 300,
          \"ResourceRecords\": [{\"Value\": \"${RECORD_VALUE}\"}]
        }
      }]
    }" --output text --query 'ChangeInfo.Id'
    echo ">> Aguardando validação do certificado (até 5 min)..."
    aws acm wait certificate-validated --certificate-arn "$CERT_ARN" --region "$REGION_ACM" 2>/dev/null || true
  fi
fi

echo ""
echo ">> Adicione em terraform/terraform.tfvars:"
echo "   acm_certificate_arn = \"${CERT_ARN}\""
echo ""
echo "   Certificado ARN: ${CERT_ARN}"
