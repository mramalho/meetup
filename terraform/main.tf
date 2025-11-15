terraform {
  required_version = ">= 1.6.0"

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

########################
# S3 - APP (SITE)
########################

resource "aws_s3_bucket" "app" {
  bucket = var.app_bucket_name

  tags = {
    Name = "aws-community-app"
  }
}

resource "aws_s3_bucket_website_configuration" "app_website" {
  bucket = aws_s3_bucket.app.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "error.html"
  }
}

resource "aws_s3_bucket_policy" "app_policy" {
  bucket = aws_s3_bucket.app.id
  depends_on = [aws_s3_bucket_public_access_block.app_public_access]

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid      = "PublicReadForWebsite",
        Effect   = "Allow",
        Principal = "*",
        Action   = ["s3:GetObject"],
        Resource = "arn:aws:s3:::${var.app_bucket_name}/*"
      }
    ]
  })
}


########################
# S3 CORS - BUCKET CPS
########################

resource "aws_s3_bucket_cors_configuration" "cps_cors" {
  bucket = var.cps_bucket_name

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "POST"]
    # Em produção você pode restringir para apenas o domínio do CloudFront
    allowed_origins = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
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
      # Listar objetos nos prefixos usados
      {
        Effect   = "Allow",
        Action   = ["s3:ListBucket"],
        Resource = "arn:aws:s3:::${var.cps_bucket_name}",
        Condition = {
          StringLike = {
            "s3:prefix" = [
              "video/*",
              "transcribe/*",
              "resumo/*"
            ]
          }
        }
      },
      # Upload de vídeos e leitura de transcrições/resumos
      {
        Effect = "Allow",
        Action = [
          "s3:PutObject",
          "s3:GetObject"
        ],
        Resource = [
          "arn:aws:s3:::${var.cps_bucket_name}/video/*",
          "arn:aws:s3:::${var.cps_bucket_name}/transcribe/*",
          "arn:aws:s3:::${var.cps_bucket_name}/resumo/*"
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
        Resource = "arn:aws:s3:::${var.cps_bucket_name}/video/*"
      },
      # opcional, se a Lambda precisar escrever algo
      {
        Effect   = "Allow",
        Action   = ["s3:PutObject"],
        Resource = "arn:aws:s3:::${var.cps_bucket_name}/transcribe/*"
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
      TRANSCRIBE_OUTPUT_BUCKET = var.cps_bucket_name
      TRANSCRIBE_OUTPUT_PREFIX = "transcribe/"
      TRANSCRIBE_LANGUAGE_CODE = "pt-BR"
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
        Effect   = "Allow",
        Action   = ["s3:GetObject"],
        Resource = "arn:aws:s3:::${var.cps_bucket_name}/transcribe/*"
      },
      {
        Effect   = "Allow",
        Action   = ["s3:PutObject"],
        Resource = "arn:aws:s3:::${var.cps_bucket_name}/resumo/*"
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
      SUMMARY_OUTPUT_BUCKET     = var.cps_bucket_name
      SUMMARY_OUTPUT_PREFIX     = "resumo/"
      BEDROCK_MODEL_ID          = var.bedrock_model_id
      BEDROCK_REGION            = var.bedrock_region
      BEDROCK_INFERENCE_PROFILE = var.bedrock_inference_profile
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
        "name" : [var.cps_bucket_name]
      },
      "object" : {
        "key" : [{
          "prefix" : "video/"
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
        "name" : [var.cps_bucket_name]
      },
      "object" : {
        "key" : [{
          "prefix" : "transcribe/"
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
# CLOUDFRONT + ROUTE53
########################

resource "aws_cloudfront_distribution" "app_cdn" {
  enabled             = true
  default_root_object = "index.html"

  aliases = [var.domain_name]

  origin {
    domain_name = aws_s3_bucket_website_configuration.app_website.website_endpoint
    origin_id   = "s3-website-app"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "s3-website-app"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD"]
    cached_methods  = ["GET", "HEAD"]
    compress        = true

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

resource "aws_s3_bucket_public_access_block" "app_public_access" {
  bucket = aws_s3_bucket.app.id

  # Desligar o bloqueio de políticas e ACLs públicas
  block_public_acls       = false
  ignore_public_acls      = false
  block_public_policy     = false
  restrict_public_buckets = false
}

