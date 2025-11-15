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
