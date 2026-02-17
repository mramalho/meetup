terraform {
  required_version = ">= 1.6.0"

  backend "s3" {
    bucket = "mramalho-tfvars"
    key    = "meetup/terraform.tfstate"
    region = "us-east-2"
  }

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

  # Permite deletar o bucket mesmo com objetos (útil para terraform destroy)
  force_destroy = true

  tags = {
    Name = var.app_bucket_name
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
  bucket     = aws_s3_bucket.app.id
  depends_on = [aws_s3_bucket_public_access_block.app_public_access]

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid       = "PublicReadForWebsite",
        Effect    = "Allow",
        Principal = "*",
        Action    = ["s3:GetObject"],
        Resource  = "${aws_s3_bucket.app.arn}/*"
      }
    ]
  })
}


########################
# S3 - BUCKET CPS (Vídeos/Transcrições/Resumos)
########################

resource "aws_s3_bucket" "cps" {
  bucket = var.cps_bucket_name

  # Permite deletar o bucket mesmo com objetos (útil para terraform destroy)
  force_destroy = true

  tags = {
    Name = var.cps_bucket_name
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cps_encryption" {
  bucket = aws_s3_bucket.cps.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_cors_configuration" "cps_cors" {
  bucket = aws_s3_bucket.cps.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "POST"]
    # Restrito ao domínio do app (evita requisições de origens não autorizadas)
    allowed_origins = [
      "https://${var.domain_name}",
      "https://${aws_cloudfront_distribution.app_cdn.domain_name}"
    ]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

# OBRIGATÓRIO: S3 só envia eventos ao EventBridge quando esta notificação está habilitada.
# Sem isso, as regras EventBridge nunca recebem eventos e as Lambdas não são disparadas.
resource "aws_s3_bucket_notification" "cps_eventbridge" {
  bucket = aws_s3_bucket.cps.id

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
      # Listar objetos nos prefixos usados
      {
        Effect   = "Allow",
        Action   = ["s3:ListBucket"],
        Resource = aws_s3_bucket.cps.arn,
        Condition = {
          StringLike = {
            "s3:prefix" = [
              "video/*",
              "transcribe/*",
              "resumo/*",
              "prompts/*",
              "models/*"
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
          "${aws_s3_bucket.cps.arn}/video/*",
          "${aws_s3_bucket.cps.arn}/transcribe/*",
          "${aws_s3_bucket.cps.arn}/resumo/*",
          "${aws_s3_bucket.cps.arn}/prompts/*",
          "${aws_s3_bucket.cps.arn}/models/*"
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
        Resource = "${aws_s3_bucket.cps.arn}/video/*"
      },
      # opcional, se a Lambda precisar escrever algo
      {
        Effect   = "Allow",
        Action   = ["s3:PutObject"],
        Resource = "${aws_s3_bucket.cps.arn}/transcribe/*"
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
      TRANSCRIBE_OUTPUT_BUCKET = aws_s3_bucket.cps.bucket
      TRANSCRIBE_OUTPUT_PREFIX = "transcribe/"
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
          "${aws_s3_bucket.cps.arn}/transcribe/*",
          "${aws_s3_bucket.cps.arn}/prompts/*",
          "${aws_s3_bucket.cps.arn}/models/*"
        ]
      },
      {
        Effect   = "Allow",
        Action   = ["s3:PutObject"],
        Resource = "${aws_s3_bucket.cps.arn}/resumo/*"
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
      SUMMARY_OUTPUT_BUCKET     = aws_s3_bucket.cps.bucket
      SUMMARY_OUTPUT_PREFIX     = "resumo/"
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
          "name" : [aws_s3_bucket.cps.bucket]
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
          "name" : [aws_s3_bucket.cps.bucket]
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

resource "aws_s3_bucket_public_access_block" "app_public_access" {
  bucket = aws_s3_bucket.app.id

  # Desligar o bloqueio de políticas e ACLs públicas
  block_public_acls       = false
  ignore_public_acls      = false
  block_public_policy     = false
  restrict_public_buckets = false
}

