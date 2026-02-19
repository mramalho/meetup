terraform {
  required_version = ">= 1.6.0"

  # Backend configurado via -backend-config nos scripts (bucket/region de config/config.env)
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Provider para recursos do Bedrock (logging) - deve estar na mesma região das invocações
provider "aws" {
  alias  = "bedrock"
  region = var.bedrock_region
}

########################
# S3 - BUCKET ÚNICO (var.bucket_name)
# Prefixos: app/ (frontend), model/ (vídeos, transcrições, resumos, prompts, models)
# O bucket é criado por setup-terraform-backend.sh antes do terraform init.
########################

data "aws_s3_bucket" "main" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_server_side_encryption_configuration" "main_encryption" {
  bucket = data.aws_s3_bucket.main.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "main_public_access" {
  bucket = data.aws_s3_bucket.main.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

locals {
  cors_origins = concat(
    [
      "https://${var.domain_name}",
      "http://${var.domain_name}",
      "https://${aws_cloudfront_distribution.app_cdn.domain_name}"
    ],
    var.cors_extra_origins != "" ? [for o in split(",", var.cors_extra_origins) : trimspace(o)] : []
  )
}

resource "aws_s3_bucket_cors_configuration" "main_cors" {
  bucket = data.aws_s3_bucket.main.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "POST", "DELETE", "HEAD"]
    allowed_origins = local.cors_origins
    expose_headers  = ["ETag", "x-amz-request-id", "x-amz-id-2"]
    max_age_seconds = 3000
  }
}

# OBRIGATÓRIO: S3 só envia eventos ao EventBridge quando esta notificação está habilitada.
resource "aws_s3_bucket_notification" "main_eventbridge" {
  bucket = data.aws_s3_bucket.main.id

  eventbridge = true
}

########################
# COGNITO IDENTITY POOL
########################

resource "aws_cognito_identity_pool" "public_identity" {
  identity_pool_name               = "aws-community-public-identity"
  allow_unauthenticated_identities = true
}

resource "aws_iam_role" "cognito_unauth_role" {
  name = "cognito-unauth-role-aws-community"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Federated = "cognito-identity.amazonaws.com"
        },
        Action = "sts:AssumeRoleWithWebIdentity",
        Condition = {
          StringEquals = {
            "cognito-identity.amazonaws.com:aud" = aws_cognito_identity_pool.public_identity.id
          },
          "ForAnyValue:StringLike" = {
            "cognito-identity.amazonaws.com:amr" = "unauthenticated"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "cognito_unauth_s3_policy" {
  role = aws_iam_role.cognito_unauth_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = ["s3:ListBucket"],
        Resource = data.aws_s3_bucket.main.arn,
        Condition = {
          StringLike = {
            "s3:prefix" = [
              "model/video/*",
              "model/transcribe/*",
              "model/resumo/*",
              "model/prompts/*",
              "model/models/*"
            ]
          }
        }
      },
      {
        Effect = "Allow",
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject"
        ],
        Resource = [
          "${data.aws_s3_bucket.main.arn}/model/video/*",
          "${data.aws_s3_bucket.main.arn}/model/transcribe/*",
          "${data.aws_s3_bucket.main.arn}/model/resumo/*",
          "${data.aws_s3_bucket.main.arn}/model/prompts/*",
          "${data.aws_s3_bucket.main.arn}/model/models/*"
        ]
      }
    ]
  })
}

resource "aws_cognito_identity_pool_roles_attachment" "pool_roles" {
  identity_pool_id = aws_cognito_identity_pool.public_identity.id

  roles = {
    unauthenticated = aws_iam_role.cognito_unauth_role.arn
  }
}

########################
# LAMBDAS + IAM
########################

# Log groups criados explicitamente para garantir que existam no CloudWatch
# (a Lambda usa /aws/lambda/<nome> automaticamente; criar antes evita ausência do grupo)
resource "aws_cloudwatch_log_group" "lambda_transcribe" {
  name              = "/aws/lambda/start-transcribe-on-s3-upload"
  retention_in_days  = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "lambda_bedrock_summary" {
  name              = "/aws/lambda/generate-summary-from-srt-bedrock"
  retention_in_days  = var.log_retention_days
}

# Lambda 1: inicia Transcribe quando vídeo chegar no S3
resource "aws_iam_role" "lambda_transcribe_role" {
  name = "lambda-transcribe-on-upload-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect    = "Allow",
        Principal = { Service = "lambda.amazonaws.com" },
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_transcribe_policy" {
  role = aws_iam_role.lambda_transcribe_role.id
  name = "lambda-transcribe-on-upload-policy"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "transcribe:StartTranscriptionJob",
          "transcribe:GetTranscriptionJob"
        ],
        Resource = "*"
      },
      {
        Effect   = "Allow",
        Action   = ["s3:GetObject"],
        Resource = "${data.aws_s3_bucket.main.arn}/model/video/*"
      },
      {
        Effect   = "Allow",
        Action   = ["s3:PutObject"],
        Resource = "${data.aws_s3_bucket.main.arn}/model/transcribe/*"
      },
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_lambda_function" "start_transcribe" {
  function_name = "start-transcribe-on-s3-upload"
  role          = aws_iam_role.lambda_transcribe_role.arn
  runtime       = "python3.12"
  handler       = "lambda_function.lambda_handler"

  filename         = "${path.module}/build/start_transcribe.zip"
  source_code_hash = filebase64sha256("${path.module}/build/start_transcribe.zip")

  timeout = 60

  environment {
    variables = {
      TRANSCRIBE_OUTPUT_BUCKET = data.aws_s3_bucket.main.bucket
      TRANSCRIBE_OUTPUT_PREFIX = "model/transcribe/"
      TRANSCRIBE_LANGUAGE_CODE = "pt-BR"
      OBSERVABILITY_DEBUG     = var.observability_debug
      OBSERVABILITY_TRACE     = var.observability_trace
    }
  }
}

# Lambda 2: lê .srt, chama Bedrock (Nova Micro) e grava resumo .md
resource "aws_iam_role" "lambda_bedrock_summary_role" {
  name = "lambda-bedrock-summary-on-srt-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect    = "Allow",
        Principal = { Service = "lambda.amazonaws.com" },
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_bedrock_summary_policy" {
  role = aws_iam_role.lambda_bedrock_summary_role.id
  name = "lambda-bedrock-summary-on-srt-policy"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = ["s3:GetObject"],
        Resource = [
          "${data.aws_s3_bucket.main.arn}/model/transcribe/*",
          "${data.aws_s3_bucket.main.arn}/model/prompts/*",
          "${data.aws_s3_bucket.main.arn}/model/models/*",
          "${data.aws_s3_bucket.main.arn}/model/video/*"
        ]
      },
      {
        Effect   = "Allow",
        Action   = ["s3:PutObject"],
        Resource = "${data.aws_s3_bucket.main.arn}/model/resumo/*"
      },
      # Permite atualizar .srt com cabeçalho do modelo LLM e remover duplicatas (meetup-*-timestamp.srt)
      {
        Effect   = "Allow",
        Action   = ["s3:PutObject", "s3:DeleteObject"],
        Resource = "${data.aws_s3_bucket.main.arn}/model/transcribe/*"
      },
      {
        Effect = "Allow",
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock:Converse",
          "bedrock:ConverseStream"
        ],
        Resource = "*"
      },
      # Necessário para inference profiles (ex.: us.anthropic.claude-haiku-4-5-20251001-v1:0)
      {
        Effect   = "Allow",
        Action   = ["bedrock:GetInferenceProfile", "bedrock:ListInferenceProfiles"],
        Resource = [
          "arn:aws:bedrock:*:*:inference-profile/*",
          "arn:aws:bedrock:*:*:application-inference-profile/*"
        ]
      },
      # Permissões AWS Marketplace necessárias para modelos Bedrock (ex.: Claude, DeepSeek)
      {
        Effect   = "Allow",
        Action   = [
          "aws-marketplace:ViewSubscriptions",
          "aws-marketplace:Subscribe",
          "aws-marketplace:Unsubscribe"
        ],
        Resource = "*"
      },
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_lambda_function" "bedrock_summary" {
  function_name = "generate-summary-from-srt-bedrock"
  role          = aws_iam_role.lambda_bedrock_summary_role.arn
  runtime       = "python3.12"
  handler       = "lambda_bedrock_summary.lambda_handler"

  filename         = "${path.module}/build/bedrock_summary.zip"
  source_code_hash = filebase64sha256("${path.module}/build/bedrock_summary.zip")

  timeout = 120

  environment {
    variables = {
      SUMMARY_OUTPUT_BUCKET     = data.aws_s3_bucket.main.bucket
      SUMMARY_OUTPUT_PREFIX     = "model/resumo/"
      MODEL_PREFIX              = "model/"
      BEDROCK_MODEL_ID          = var.bedrock_model_id
      BEDROCK_REGION            = var.bedrock_region
      BEDROCK_INFERENCE_PROFILE = var.bedrock_inference_profile
      OBSERVABILITY_DEBUG      = var.observability_debug
      OBSERVABILITY_TRACE      = var.observability_trace
    }
  }
}

########################
# EVENTBRIDGE RULES
########################

# Vídeo mp4 -> Lambda Transcribe
resource "aws_cloudwatch_event_rule" "s3_video_upload" {
  name        = "s3-video-upload-to-transcribe"
  description = "Dispara Lambda ao criar objeto .mp4 em video/"

  event_pattern = jsonencode({
    "source" : ["aws.s3"],
    "detail-type" : ["Object Created"],
      "detail" : {
        "bucket" : {
          "name" : [data.aws_s3_bucket.main.bucket]
        },
      "object" : {
        "key" : [{
          "prefix" : "model/video/"
        }]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "s3_video_upload_lambda" {
  rule      = aws_cloudwatch_event_rule.s3_video_upload.name
  target_id = "invoke-lambda-start-transcribe"
  arn       = aws_lambda_function.start_transcribe.arn
}

resource "aws_lambda_permission" "allow_eventbridge_invoke" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.start_transcribe.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.s3_video_upload.arn
}

# .srt -> Lambda Bedrock
resource "aws_cloudwatch_event_rule" "s3_srt_created" {
  name        = "s3-srt-created-to-bedrock-summary"
  description = "Dispara Lambda ao criar arquivo .srt em transcribe/"

  event_pattern = jsonencode({
    "source" : ["aws.s3"],
    "detail-type" : ["Object Created"],
      "detail" : {
        "bucket" : {
          "name" : [data.aws_s3_bucket.main.bucket]
        },
      "object" : {
        "key" : [{
          "prefix" : "model/transcribe/"
        }]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "s3_srt_created_lambda" {
  rule      = aws_cloudwatch_event_rule.s3_srt_created.name
  target_id = "invoke-lambda-bedrock-summary"
  arn       = aws_lambda_function.bedrock_summary.arn
}

resource "aws_lambda_permission" "allow_eventbridge_invoke_bedrock_summary" {
  statement_id  = "AllowExecutionFromEventBridgeBedrockSummary"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.bedrock_summary.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.s3_srt_created.arn
}

########################
# BEDROCK MODEL INVOCATION LOGGING (análises posteriores, auditoria)
# CloudWatch Logs + S3 para dados >100KB (transcrições longas não aparecem sem isso)
########################

data "aws_caller_identity" "current" {}

locals {
  bedrock_large_data_bucket = "${var.bucket_name}-bedrock-logs"
}

resource "aws_s3_bucket" "bedrock_large_data" {
  provider = aws.bedrock

  bucket        = local.bedrock_large_data_bucket
  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" "bedrock_large_data" {
  provider = aws.bedrock

  bucket = aws_s3_bucket.bedrock_large_data.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }

  depends_on = [aws_s3_bucket.bedrock_large_data]
}

resource "aws_s3_bucket_public_access_block" "bedrock_large_data" {
  provider = aws.bedrock

  bucket = aws_s3_bucket.bedrock_large_data.id

  block_public_acls      = true
  block_public_policy    = true
  ignore_public_acls     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "bedrock_large_data" {
  provider = aws.bedrock

  bucket = aws_s3_bucket.bedrock_large_data.id

  depends_on = [
    aws_s3_bucket_public_access_block.bedrock_large_data,
    aws_s3_bucket_ownership_controls.bedrock_large_data,
  ]

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "AmazonBedrockLogsWrite",
        Effect = "Allow",
        Principal = {
          Service = "bedrock.amazonaws.com"
        },
        Action   = ["s3:PutObject"],
        Resource = "${aws_s3_bucket.bedrock_large_data.arn}/bedrock/AWSLogs/${data.aws_caller_identity.current.account_id}/BedrockModelInvocationLogs/*",
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          },
          ArnLike = {
            "aws:SourceArn" = "arn:aws:bedrock:${var.bedrock_region}:${data.aws_caller_identity.current.account_id}:*"
          }
        }
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "bedrock_invocation_logs" {
  provider = aws.bedrock

  name             = "/aws/bedrock/model-invocation-logs"
  retention_in_days = var.bedrock_logs_retention_days
}

resource "aws_iam_role" "bedrock_logging" {
  provider = aws.bedrock

  name = "bedrock-model-invocation-logging-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "bedrock.amazonaws.com"
        },
        Action = "sts:AssumeRole",
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          },
          ArnLike = {
            "aws:SourceArn" = "arn:aws:bedrock:${var.bedrock_region}:${data.aws_caller_identity.current.account_id}:*"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "bedrock_logging" {
  provider = aws.bedrock

  name   = "bedrock-logging-policy"
  role   = aws_iam_role.bedrock_logging.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "${aws_cloudwatch_log_group.bedrock_invocation_logs.arn}:log-stream:aws/bedrock/modelinvocations"
      }
    ]
  })
}

resource "aws_bedrock_model_invocation_logging_configuration" "main" {
  provider = aws.bedrock

  logging_config {
    text_data_delivery_enabled      = true
    image_data_delivery_enabled     = false
    embedding_data_delivery_enabled = false
    video_data_delivery_enabled     = false

    cloudwatch_config {
      log_group_name = aws_cloudwatch_log_group.bedrock_invocation_logs.name
      role_arn       = aws_iam_role.bedrock_logging.arn

      # Dados >100KB (transcrições longas) vão para S3; sem isso, nada é logado
      large_data_delivery_s3_config {
        bucket_name = aws_s3_bucket.bedrock_large_data.id
        key_prefix  = "bedrock"
      }
    }
  }
}

########################
# CLOUDFRONT + ROUTE53
########################

resource "aws_cloudfront_origin_access_control" "app_oac" {
  name                              = "meetup-app-oac"
  description                       = "OAC para CloudFront acessar app/ no bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_s3_bucket_policy" "main_cloudfront" {
  bucket = data.aws_s3_bucket.main.id

  depends_on = [aws_s3_bucket_public_access_block.main_public_access]

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid       = "AllowCloudFrontApp",
        Effect    = "Allow",
        Principal = { Service = "cloudfront.amazonaws.com" },
        Action    = "s3:GetObject",
        Resource  = "${data.aws_s3_bucket.main.arn}/app/*",
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.app_cdn.arn
          }
        }
      }
    ]
  })
}

resource "aws_cloudfront_response_headers_policy" "security_headers" {
  name = "security-headers-meetup"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains           = true
      override                    = true
    }
    content_type_options {
      override = true
    }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    xss_protection {
      mode_block = true
      protection = true
      override  = true
    }
    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override       = true
    }
  }
}

resource "aws_cloudfront_distribution" "app_cdn" {
  enabled             = true
  default_root_object = "index.html"

  aliases = [var.domain_name]

  origin {
    domain_name              = data.aws_s3_bucket.main.bucket_regional_domain_name
    origin_id                = "s3-app"
    origin_path              = "/app"
    origin_access_control_id = aws_cloudfront_origin_access_control.app_oac.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-app"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD"]
    cached_methods  = ["GET", "HEAD"]
    compress        = true

    response_headers_policy_id = aws_cloudfront_response_headers_policy.security_headers.id

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  price_class = "PriceClass_100"

  viewer_certificate {
    acm_certificate_arn      = var.acm_certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  custom_error_response {
    error_code            = 404
    response_code         = 404
    response_page_path    = "/error.html"
    error_caching_min_ttl = 10
  }

  custom_error_response {
    error_code            = 403
    response_code         = 404
    response_page_path    = "/error.html"
    error_caching_min_ttl = 10
  }
}

resource "aws_route53_record" "app_alias" {
  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.app_cdn.domain_name
    zone_id                = aws_cloudfront_distribution.app_cdn.hosted_zone_id
    evaluate_target_health = false
  }
}


