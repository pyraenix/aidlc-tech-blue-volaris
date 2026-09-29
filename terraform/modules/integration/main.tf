variable "name_prefix" { type = string }
variable "frames_bucket" { type = string } # arn
variable "frames_bucket_name" { type = string }
variable "bedrock_model_id" { type = string }
variable "region" { type = string }

# Non-secret base URLs of the two REST integrations. The API keys are NOT here —
# they are held by the EventBridge API Connections below (connection-managed
# secret in Secrets Manager) and injected by the Step Functions HTTP Task.
variable "upstream_data_base_url" { type = string }
variable "upstream_data_api_key" {
  type      = string
  sensitive = true
}
variable "video_agent_base_url" { type = string }
variable "video_agent_api_key" {
  type      = string
  sensitive = true
}

# ===========================================================================
# Integration layer. This app is a COMPONENT of a larger UK ecosystem:
#   - upstream EPC/compliance data  -> pulled by a native Step Functions HTTP
#     Task (no Lambda); see modules/workflow + the ASL FetchInputData state.
#   - in-house video->image agent   -> called by a native Step Functions HTTP
#     Task (no Lambda); see the ASL InvokeVideoAgent state.
#   - generate-description          -> Bedrock Claude on the agent's snapshots
#     + inputs. Kept as a Lambda: it assembles the multimodal (base64 image)
#     Bedrock payload and does a parse-and-retry loop that ASL cannot express.
#
# The two REST calls authenticate via EventBridge API Connections. Each
# connection stores its API key in a connection-managed Secrets Manager secret
# and injects it as the x-api-key header — so no credential is baked into code,
# state, or the state-machine definition.
# ===========================================================================

# --- API Connections for the two REST integrations --------------------------
resource "aws_cloudwatch_event_connection" "upstream_data" {
  name               = "${var.name_prefix}-upstream-data"
  description        = "Upstream EPC/compliance data app (x-api-key)."
  authorization_type = "API_KEY"
  auth_parameters {
    api_key {
      key   = "x-api-key"
      value = var.upstream_data_api_key
    }
  }
}

resource "aws_cloudwatch_event_connection" "video_agent" {
  name               = "${var.name_prefix}-video-agent"
  description        = "TechBlue in-house video->image agent (x-api-key)."
  authorization_type = "API_KEY"
  auth_parameters {
    api_key {
      key   = "x-api-key"
      value = var.video_agent_api_key
    }
  }
}

# --- Secret for the publishing app (still consumed by publish-to-ecosystem) --
resource "aws_secretsmanager_secret" "publish_app" {
  name        = "${var.name_prefix}-integration-publish-app"
  description = "Base URL + API key for the existing publishing application."
}

# --- generate-description Lambda (kept — Bedrock vision payload + retry) -----
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

# Tightened: generate-description only needs Bedrock (one model), read access to
# the frames bucket, and X-Ray. No Secrets Manager, no DynamoDB.
resource "aws_iam_role_policy" "integration" {
  name = "${var.name_prefix}-integration-perms"
  role = aws_iam_role.integration.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:GetObject"], Resource = "${var.frames_bucket}/*" },
      { Effect = "Allow", Action = ["bedrock:InvokeModel"], Resource = "arn:aws:bedrock:${var.region}::foundation-model/${var.bedrock_model_id}" },
      { Effect = "Allow", Action = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"], Resource = "*" },
    ]
  })
}

data "archive_file" "generate_description" {
  type        = "zip"
  source_dir  = "${path.root}/../lambdas/generate-description"
  output_path = "${path.module}/build/generate-description.zip"
}

resource "aws_lambda_function" "generate_description" {
  function_name    = "${var.name_prefix}-generate-description"
  role             = aws_iam_role.integration.arn
  runtime          = "nodejs20.x"
  handler          = "index.handler"
  filename         = data.archive_file.generate_description.output_path
  source_code_hash = data.archive_file.generate_description.output_base64sha256
  timeout          = 120
  memory_size      = 1024
  tracing_config { mode = "Active" }
  environment {
    variables = {
      BEDROCK_MODEL_ID = var.bedrock_model_id
      FRAMES_BUCKET    = var.frames_bucket_name
    }
  }
}

output "generate_description_fn_arn" { value = aws_lambda_function.generate_description.arn }

# API Connection ARNs + the connection-managed secret ARNs (the state-machine
# role needs both: RetrieveConnectionCredentials + read the managed secret).
output "upstream_data_connection_arn" { value = aws_cloudwatch_event_connection.upstream_data.arn }
output "upstream_data_connection_secret_arn" { value = aws_cloudwatch_event_connection.upstream_data.secret_arn }
output "video_agent_connection_arn" { value = aws_cloudwatch_event_connection.video_agent.arn }
output "video_agent_connection_secret_arn" { value = aws_cloudwatch_event_connection.video_agent.secret_arn }

output "publish_app_secret_arn" { value = aws_secretsmanager_secret.publish_app.arn }
