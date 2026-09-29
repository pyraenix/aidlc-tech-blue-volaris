variable "name_prefix" { type = string }
variable "frames_bucket" { type = string } # arn
variable "frames_bucket_name" { type = string }
variable "raw_videos_bucket" { type = string } # arn
variable "listings_table_arn" { type = string }
variable "listings_table_name" { type = string }
variable "bedrock_model_id" { type = string }
variable "region" { type = string }

# ===========================================================================
# Integration layer. This app is a COMPONENT of a larger UK ecosystem:
#   - fetch-input-data     -> pulls EPC/compliance data from the UPSTREAM app (REST)
#   - invoke-video-agent   -> calls TechBlue's IN-HOUSE video->image agent (REST)
#   - generate-description -> Bedrock Claude on the agent's snapshots + inputs
# External base URLs + API keys live in Secrets Manager (one secret each), so no
# endpoints or credentials are baked into code or state.
# ===========================================================================

# --- Secrets Manager entries for the three external integrations ------------
resource "aws_secretsmanager_secret" "video_agent" {
  name        = "${var.name_prefix}-integration-video-agent"
  description = "Base URL + API key for TechBlue's in-house video->image agent."
}
resource "aws_secretsmanager_secret" "input_data" {
  name        = "${var.name_prefix}-integration-input-data"
  description = "Base URL + API key for the upstream EPC/compliance data app."
}
resource "aws_secretsmanager_secret" "publish_app" {
  name        = "${var.name_prefix}-integration-publish-app"
  description = "Base URL + API key for the existing publishing application."
}

# --- Shared execution role --------------------------------------------------
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "integration" {
  name               = "${var.name_prefix}-integration"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "basic" {
  role       = aws_iam_role.integration.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "integration" {
  name = "${var.name_prefix}-integration-perms"
  role = aws_iam_role.integration.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Read snapshots the in-house agent wrote (if it writes to our bucket).
      { Effect = "Allow", Action = ["s3:GetObject"], Resource = "${var.frames_bucket}/*" },
      # Bedrock scoped to the one model, not "*".
      { Effect = "Allow", Action = ["bedrock:InvokeModel"], Resource = "arn:aws:bedrock:${var.region}::foundation-model/${var.bedrock_model_id}" },
      { Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:UpdateItem"], Resource = var.listings_table_arn },
      # Only the three integration secrets.
      { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = [
        aws_secretsmanager_secret.video_agent.arn,
        aws_secretsmanager_secret.input_data.arn,
        aws_secretsmanager_secret.publish_app.arn,
      ] },
      { Effect = "Allow", Action = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"], Resource = "*" },
    ]
  })
}

# --- Lambdas ----------------------------------------------------------------
locals {
  fns = {
    fetch_input_data     = { dir = "fetch-input-data", timeout = 30, mem = 256, env = { INPUT_DATA_SECRET_ID = "${var.name_prefix}-integration-input-data" } }
    invoke_video_agent   = { dir = "invoke-video-agent", timeout = 120, mem = 256, env = { VIDEO_AGENT_SECRET_ID = "${var.name_prefix}-integration-video-agent" } }
    generate_description = { dir = "generate-description", timeout = 120, mem = 1024, env = { BEDROCK_MODEL_ID = var.bedrock_model_id, FRAMES_BUCKET = var.frames_bucket_name } }
  }
}

data "archive_file" "fn" {
  for_each    = local.fns
  type        = "zip"
  source_dir  = "${path.root}/../lambdas/${each.value.dir}"
  output_path = "${path.module}/build/${each.key}.zip"
}

resource "aws_lambda_function" "fn" {
  for_each         = local.fns
  function_name    = "${var.name_prefix}-${each.key}"
  role             = aws_iam_role.integration.arn
  runtime          = "nodejs20.x"
  handler          = "index.handler"
  filename         = data.archive_file.fn[each.key].output_path
  source_code_hash = data.archive_file.fn[each.key].output_base64sha256
  timeout          = each.value.timeout
  memory_size      = each.value.mem
  tracing_config { mode = "Active" }
  environment {
    variables = each.value.env
  }
}

output "fetch_input_data_fn_arn" { value = aws_lambda_function.fn["fetch_input_data"].arn }
output "invoke_video_agent_fn_arn" { value = aws_lambda_function.fn["invoke_video_agent"].arn }
output "generate_description_fn_arn" { value = aws_lambda_function.fn["generate_description"].arn }

output "video_agent_secret_arn" { value = aws_secretsmanager_secret.video_agent.arn }
output "input_data_secret_arn" { value = aws_secretsmanager_secret.input_data.arn }
output "publish_app_secret_arn" { value = aws_secretsmanager_secret.publish_app.arn }
