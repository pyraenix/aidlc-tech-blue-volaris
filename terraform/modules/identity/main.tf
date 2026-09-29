variable "name_prefix" { type = string }
variable "otp_email_from" { type = string }
variable "otp_code_ttl_seconds" { type = number }
variable "access_token_validity_minutes" { type = number }
variable "app_domains" { type = list(string) }

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# ===========================================================================
# Passwordless email-OTP via Cognito CUSTOM_AUTH triggers.
# Cognito owns token issuance, refresh, attempt limits and lockout; the three
# trigger Lambdas implement "generate a 6-digit code, email it via SES, verify
# it". This removes the hand-rolled brute-force surface.
# ===========================================================================

resource "aws_cognito_user_pool" "main" {
  name              = "${var.name_prefix}-users"
  mfa_configuration = "OFF"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  # Passwordless: users never set a password, but Cognito requires a policy.
  password_policy {
    minimum_length    = 16
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = true
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  lambda_config {
    define_auth_challenge          = aws_lambda_function.define_auth.arn
    create_auth_challenge          = aws_lambda_function.create_auth.arn
    verify_auth_challenge_response = aws_lambda_function.verify_auth.arn
  }

  # Email via SES (not the Cognito default sandbox sender).
  email_configuration {
    email_sending_account = "DEVELOPER"
    from_email_address    = var.otp_email_from
    source_arn            = "arn:aws:ses:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:identity/${var.otp_email_from}"
  }
}

# Reviewer role groups — the group claim drives console authority server-side.
resource "aws_cognito_user_group" "approvers" {
  name         = "approvers"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "Can approve/reject listings."
}

resource "aws_cognito_user_group" "editors" {
  name         = "editors"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "Can edit drafts but not final-approve."
}

resource "aws_cognito_user_pool_client" "web" {
  name            = "${var.name_prefix}-web"
  user_pool_id    = aws_cognito_user_pool.main.id
  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_CUSTOM_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  access_token_validity  = var.access_token_validity_minutes
  id_token_validity      = var.access_token_validity_minutes
  refresh_token_validity = 30
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  prevent_user_existence_errors = "ENABLED"
  supported_identity_providers  = ["COGNITO"]
}

# --- Trigger Lambdas --------------------------------------------------------
data "aws_iam_policy_document" "trigger_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "trigger" {
  name               = "${var.name_prefix}-cognito-trigger"
  assume_role_policy = data.aws_iam_policy_document.trigger_assume.json
}

resource "aws_iam_role_policy_attachment" "trigger_basic" {
  role       = aws_iam_role.trigger.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# create_auth needs SES to send the code email.
resource "aws_iam_role_policy" "trigger_ses" {
  name = "${var.name_prefix}-cognito-ses"
  role = aws_iam_role.trigger.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ses:SendEmail", "ses:SendRawEmail"]
      Resource = "*"
    }]
  })
}

locals {
  triggers = {
    define_auth = "define-auth-challenge"
    create_auth = "create-auth-challenge"
    verify_auth = "verify-auth-challenge"
  }
}

data "archive_file" "trigger" {
  for_each    = local.triggers
  type        = "zip"
  source_file = "${path.module}/src/${each.value}.js"
  output_path = "${path.module}/build/${each.value}.zip"
}

resource "aws_lambda_function" "define_auth" {
  function_name    = "${var.name_prefix}-define-auth"
  role             = aws_iam_role.trigger.arn
  runtime          = "nodejs20.x"
  handler          = "define-auth-challenge.handler"
  filename         = data.archive_file.trigger["define_auth"].output_path
  source_code_hash = data.archive_file.trigger["define_auth"].output_base64sha256
  timeout          = 5
}

resource "aws_lambda_function" "create_auth" {
  function_name    = "${var.name_prefix}-create-auth"
  role             = aws_iam_role.trigger.arn
  runtime          = "nodejs20.x"
  handler          = "create-auth-challenge.handler"
  filename         = data.archive_file.trigger["create_auth"].output_path
  source_code_hash = data.archive_file.trigger["create_auth"].output_base64sha256
  timeout          = 10
  environment {
    variables = {
      OTP_FROM        = var.otp_email_from
      OTP_TTL_SECONDS = tostring(var.otp_code_ttl_seconds)
    }
  }
}

resource "aws_lambda_function" "verify_auth" {
  function_name    = "${var.name_prefix}-verify-auth"
  role             = aws_iam_role.trigger.arn
  runtime          = "nodejs20.x"
  handler          = "verify-auth-challenge.handler"
  filename         = data.archive_file.trigger["verify_auth"].output_path
  source_code_hash = data.archive_file.trigger["verify_auth"].output_base64sha256
  timeout          = 5
}

resource "aws_lambda_permission" "cognito_invoke" {
  for_each      = { define = aws_lambda_function.define_auth.function_name, create = aws_lambda_function.create_auth.function_name, verify = aws_lambda_function.verify_auth.function_name }
  statement_id  = "AllowCognitoInvoke-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = each.value
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.main.arn
}

output "user_pool_id" { value = aws_cognito_user_pool.main.id }
output "user_pool_arn" { value = aws_cognito_user_pool.main.arn }
output "user_pool_client_id" { value = aws_cognito_user_pool_client.web.id }
