variable "aws_region" {
  description = "Região principal dos recursos"
  type        = string
  default     = "us-east-2"
}

variable "app_bucket_name" {
  description = "Bucket S3 para hospedar o app estático"
  type        = string
  default     = "aws-community-app"
}

variable "cps_bucket_name" {
  description = "Bucket S3 já existente com vídeos/transcrições/resumos"
  type        = string
  default     = "aws-community-cps"
}

variable "domain_name" {
  description = "Domínio para o CloudFront"
  type        = string
  default     = "meetup.ramalho.dev.br"
}

variable "acm_certificate_arn" {
  description = "ARN do certificado ACM em us-east-1 para o domínio"
  type        = string
}

variable "hosted_zone_id" {
  description = "ID da Hosted Zone em Route53 (por ex: para ramalho.dev.br)"
  type        = string
}

variable "bedrock_region" {
  description = "Região usada para invocar o Bedrock"
  type        = string
  default     = "us-east-2"
}

variable "bedrock_model_id" {
  description = "ID do modelo do Bedrock"
  type        = string
  default     = "deepseek.r1-v1:0"
}

variable "bedrock_inference_profile" {
  description = "ID do inference profile do Bedrock (necessário para alguns modelos como deepseek.r1-v1:0). Use 'us.deepseek.r1-v1:0' para DeepSeek R1."
  type        = string
  default     = "us.deepseek.r1-v1:0"
}
