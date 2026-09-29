variable "name_prefix" { type = string }
variable "app_domains" { type = list(string) }
variable "keycloak_issuer" { type = string }
variable "keycloak_audience" { type = list(string) }
variable "raw_videos_bucket" { type = string }
variable "max_upload_mb" { type = number }
variable "listings_table_arn" { type = string }
variable "listings_table_name" { type = string }
variable "redis_endpoint" { type = string }
variable "vpc_subnet_ids" { type = list(string) }
variable "lambda_sg_id" { type = string }
variable "waf_acl_arn" { type = string }

# ===========================================================================
# HTTP API (API Gateway v2) with a JWT authorizer that trusts self-hosted
# Keycloak.
# Routes:
#   POST /presign          (auth)   -> presign-upload
#   POST /listings/submit  (auth)   -> submit-for-review draft->pipeline
#   POST /review/decision  (auth)   -> review-callback (SendTaskSuccess/Failure)
# Login (incl. passwordless email-OTP) is owned entirely by Keycloak: the SPAs
# run the OIDC auth-code + PKCE flow against Keycloak directly, then call these
# routes with the resulting bearer token. The authorizer validates each token
# against Keycloak's OIDC issuer / JWKS. Because API Gateway's native JWT
# authorizer fetches JWKS over the public internet, keycloak_issuer must be a
# publicly reachable https URL.
# ===========================================================================

resource "aws_apigatewayv2_api" "main" {
  name          = "${var.name_prefix}-api"
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins = var.app_domains
    allow_methods = ["POST", "GET", "OPTIONS"]
    allow_headers = ["authorization", "content-type"]
    max_age       = 3000
  }
}

resource "aws_apigatewayv2_authorizer" "jwt" {
  api_id           = aws_apigatewayv2_api.main.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "${var.name_prefix}-keycloak-jwt"
  jwt_configuration {
    audience = var.keycloak_audience
    issuer   = var.keycloak_issuer
  }
}

# --- Shared role for the API Lambdas ----------------------------------------
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "api" {
  name               = "${var.name_prefix}-api-lambda"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "basic" {
  role       = aws_iam_role.api.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# submit-for-review is VPC-attached (needs Redis) -> ENI perms.
resource "aws_iam_role_policy_attachment" "vpc" {
  role       = aws_iam_role.api.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "api" {
  name = "${var.name_prefix}-api-perms"
  role = aws_iam_role.api.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:PutObject"], Resource = "arn:aws:s3:::${var.raw_videos_bucket}/listings/*" },
      { Effect = "Allow", Action = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem", "dynamodb:Query"], Resource = [var.listings_table_arn, "${var.listings_table_arn}/index/*"] },
      { Effect = "Allow", Action = ["states:SendTaskSuccess", "states:SendTaskFailure"], Resource = "*" },
      { Effect = "Allow", Action = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"], Resource = "*" },
    ]
  })
}

# --- Lambdas ----------------------------------------------------------------
locals {
  api_fns = {
    presign_upload    = { dir = "presign-upload", vpc = false }
    submit_for_review = { dir = "submit-for-review", vpc = false }
    review_callback   = { dir = "review-callback", vpc = false }
  }
}

data "archive_file" "api_fn" {
  for_each    = local.api_fns
  type        = "zip"
  source_dir  = "${path.root}/../lambdas/${each.value.dir}"
  output_path = "${path.module}/build/${each.key}.zip"
}

resource "aws_lambda_function" "api_fn" {
  for_each         = local.api_fns
  function_name    = "${var.name_prefix}-${each.key}"
  role             = aws_iam_role.api.arn
  runtime          = "nodejs20.x"
  handler          = "index.handler"
  filename         = data.archive_file.api_fn[each.key].output_path
  source_code_hash = data.archive_file.api_fn[each.key].output_base64sha256
  timeout          = 30
  tracing_config { mode = "Active" }

  dynamic "vpc_config" {
    for_each = each.value.vpc ? [1] : []
    content {
      subnet_ids         = var.vpc_subnet_ids
      security_group_ids = [var.lambda_sg_id]
    }
  }

  environment {
    variables = {
      RAW_BUCKET     = var.raw_videos_bucket
      MAX_UPLOAD_MB  = tostring(var.max_upload_mb)
      LISTINGS_TABLE = var.listings_table_name
      REDIS_ENDPOINT = var.redis_endpoint
    }
  }
}

# --- Routes + integrations --------------------------------------------------
locals {
  routes = {
    "POST /presign"         = "presign_upload"
    "POST /listings/submit" = "submit_for_review"
    "POST /review/decision" = "review_callback"
  }
}

resource "aws_apigatewayv2_integration" "fn" {
  for_each               = aws_lambda_function.api_fn
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = each.value.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "r" {
  for_each           = local.routes
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = each.key
  target             = "integrations/${aws_apigatewayv2_integration.fn[each.value].id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.jwt.id
}

resource "aws_lambda_permission" "apigw" {
  for_each      = aws_lambda_function.api_fn
  statement_id  = "AllowAPIGW"
  action        = "lambda:InvokeFunction"
  function_name = each.value.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 200
    throttling_rate_limit  = 100
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api.arn
    format = jsonencode({
      requestId = "$context.requestId", ip = "$context.identity.sourceIp",
      method    = "$context.httpMethod", route = "$context.routeKey",
      status    = "$context.status", error = "$context.error.message"
    })
  }
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/apigw/${var.name_prefix}"
  retention_in_days = 90
}

# WAF association (regional).
resource "aws_wafv2_web_acl_association" "api" {
  resource_arn = aws_apigatewayv2_stage.default.arn
  web_acl_arn  = var.waf_acl_arn
}

output "api_id" { value = aws_apigatewayv2_api.main.id }
output "api_base_url" { value = aws_apigatewayv2_stage.default.invoke_url }
output "submit_for_review_fn_arn" { value = aws_lambda_function.api_fn["submit_for_review"].arn }
