variable "name_prefix" { type = string }
variable "event_bus_name" { type = string }
variable "event_bus_arn" { type = string }
variable "listings_table_arn" { type = string }
variable "listings_table_name" { type = string }
variable "publish_app_secret_arn" { type = string }
variable "publish_app_secret_name" { type = string }

# On ListingApproved, hand the approved listing to TechBlue's EXISTING
# publishing application over REST. Single integration Lambda + a DLQ for
# failures (EventBridge retries, then dead-letters).
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "publish" {
  name               = "${var.name_prefix}-publish"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "basic" {
  role       = aws_iam_role.publish.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "publish" {
  name = "${var.name_prefix}-publish-perms"
  role = aws_iam_role.publish.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:UpdateItem"], Resource = var.listings_table_arn },
      { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = var.publish_app_secret_arn },
      { Effect = "Allow", Action = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"], Resource = "*" },
    ]
  })
}

data "archive_file" "publish" {
  type        = "zip"
  source_dir  = "${path.root}/../lambdas/publish-to-ecosystem"
  output_path = "${path.module}/build/publish-to-ecosystem.zip"
}

resource "aws_lambda_function" "publish" {
  function_name    = "${var.name_prefix}-publish-to-ecosystem"
  role             = aws_iam_role.publish.arn
  runtime          = "nodejs20.x"
  handler          = "index.handler"
  filename         = data.archive_file.publish.output_path
  source_code_hash = data.archive_file.publish.output_base64sha256
  timeout          = 60
  tracing_config { mode = "Active" }
  environment {
    variables = {
      LISTINGS_TABLE        = var.listings_table_name
      PUBLISH_APP_SECRET_ID = var.publish_app_secret_name
    }
  }
}

# DLQ for failed hand-offs to the publishing app.
resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name_prefix}-publish-dlq"
  message_retention_seconds = 1209600
}

# EventBridge rule -> the publish Lambda, with retry + DLQ.
resource "aws_cloudwatch_event_rule" "approved" {
  name           = "${var.name_prefix}-publish-on-approved"
  event_bus_name = var.event_bus_name
  event_pattern = jsonencode({
    source        = ["techblue.onboarding"]
    "detail-type" = ["ListingApproved"]
  })
}

resource "aws_cloudwatch_event_target" "to_lambda" {
  rule           = aws_cloudwatch_event_rule.approved.name
  event_bus_name = var.event_bus_name
  target_id      = "publish"
  arn            = aws_lambda_function.publish.arn

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 5
  }
  dead_letter_config {
    arn = aws_sqs_queue.dlq.arn
  }
}

resource "aws_lambda_permission" "eb" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.publish.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.approved.arn
}

# Let EventBridge write failed events to the DLQ.
resource "aws_sqs_queue_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.dlq.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.approved.arn } }
    }]
  })
}

output "publish_dlq_url" { value = aws_sqs_queue.dlq.url }
