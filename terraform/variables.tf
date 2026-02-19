variable "aws_region" {
  description = "Região principal dos recursos"
  type        = string
  default     = "us-east-2"
}

variable "bucket_name" {
  description = "Bucket S3 único - app em app/, dados em model/. Deve ser definido em config/config.env (BUCKET_NAME)."
  type        = string
}

variable "domain_name" {
  description = "Domínio para o CloudFront. Deve ser definido em config/config.env (DOMAIN_NAME)."
  type        = string
}

variable "acm_certificate_arn" {
  description = "ARN do certificado ACM em us-east-1 para o domínio"
  type        = string
}

variable "hosted_zone_id" {
  description = "ID da Hosted Zone em Route53 para o domínio"
  type        = string
}

variable "cors_extra_origins" {
  description = "Origens extras para CORS do S3 (separadas por vírgula). Ex: http://localhost:8080,http://127.0.0.1:8080 para desenvolvimento local."
  type        = string
  default     = ""
}

variable "bedrock_region" {
  description = "Região usada para invocar o Bedrock"
  type        = string
  default     = "us-east-2"
}

variable "bedrock_model_id" {
  description = "ID do modelo do Bedrock"
  type        = string
  # default     = "deepseek.r1-v1:0"
  # default = "amazon.nova-lite-v1:0"
  default     = "anthropic.claude-haiku-4-5-20251001-v1:0"
}

variable "bedrock_inference_profile" {
  description = "ID do inference profile do Bedrock (necessário para alguns modelos como deepseek.r1-v1:0). Use 'us.deepseek.r1-v1:0' para DeepSeek R1. Deixe vazio ('') para modelos que não requerem inference profile."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  description = "Dias de retenção dos logs das Lambdas no CloudWatch (0 = retenção indefinida)"
  type        = number
  default     = 30
}

variable "bedrock_logs_retention_days" {
  description = "Dias de retenção dos logs do Bedrock no CloudWatch (0 = retenção indefinida)"
  type        = number
  default     = 30
}

variable "observability_debug" {
  description = "Feature flag: 1 = log detalhado (evento completo, respostas API) no CloudWatch. Use para troubleshooting."
  type        = string
  default     = "0"
}

variable "observability_trace" {
  description = "Feature flag: 1 = log de cada etapa do fluxo (trace). Use para debugging."
  type        = string
  default     = "0"
}
