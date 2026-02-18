output "aws_region" {
  description = "Região AWS"
  value       = var.aws_region
}

output "cloudfront_domain_name" {
  description = "Domínio do CloudFront"
  value       = aws_cloudfront_distribution.app_cdn.domain_name
}

output "app_url" {
  description = "URL do app"
  value       = "https://${var.domain_name}"
}

output "identity_pool_id" {
  description = "ID do Cognito Identity Pool (para usar no app.js)"
  value       = aws_cognito_identity_pool.public_identity.id
}

output "bucket_name" {
  description = "Nome do bucket único"
  value       = data.aws_s3_bucket.main.id
}

output "app_prefix" {
  description = "Prefix do app no bucket"
  value       = "app/"
}

output "model_prefix" {
  description = "Prefix dos dados (vídeos, transcrições, resumos) no bucket"
  value       = "model/"
}

output "cloudfront_distribution_id" {
  description = "ID da distribuição CloudFront (para deploy e invalidação)"
  value       = aws_cloudfront_distribution.app_cdn.id
}
