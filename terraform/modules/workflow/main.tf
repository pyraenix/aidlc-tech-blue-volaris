variable "name_prefix" { type = string }
variable "listings_table_name" { type = string }
variable "listings_table_arn" { type = string }
variable "frames_bucket_name" { type = string }
variable "event_bus_name" { type = string }
variable "event_bus_arn" { type = string }
variable "fetch_input_data_fn_arn" { type = string }
variable "invoke_video_agent_fn_arn" { type = string }
variable "generate_description_fn_arn" { type = string }
variable "submit_for_review_fn_arn" { type = string }
variable "owner_notify_topic_arn" { type = string }
variable "ops_notify_topic_arn" { type = string }

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# --- Step Functions execution role ------------------------------------------
data "aws_iam_policy_document" "sfn_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sfn" {
  name               = "${var.name_prefix}-sfn"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
}

resource "aws_iam_role_policy" "sfn" {
  name = "${var.name_prefix}-sfn-perms"
  role = aws_iam_role.sfn.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["lambda:InvokeFunction"]
        Resource = [
          var.fetch_input_data_fn_arn,
          var.invoke_video_agent_fn_arn,
          var.generate_description_fn_arn,
          var.submit_for_review_fn_arn,
        ]
      },
      { Effect = "Allow", Action = ["dynamodb:UpdateItem"], Resource = var.listings_table_arn },
      { Effect = "Allow", Action = ["events:PutEvents"], Resource = var.event_bus_arn },
      { Effect = "Allow", Action = ["sns:Publish"], Resource = [var.owner_notify_topic_arn, var.ops_notify_topic_arn] },
      { Effect = "Allow", Action = ["logs:CreateLogDelivery", "logs:GetLogDelivery", "logs:UpdateLogDelivery", "logs:DeleteLogDelivery", "logs:ListLogDeliveries", "logs:PutResourcePolicy", "logs:DescribeResourcePolicies", "logs:DescribeLogGroups"], Resource = "*" },
      { Effect = "Allow", Action = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"], Resource = "*" },
    ]
  })
}

resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/states/${var.name_prefix}-onboarding"
  retention_in_days = 90
}

resource "aws_sfn_state_machine" "onboarding" {
  name     = "${var.name_prefix}-onboarding"
  role_arn = aws_iam_role.sfn.arn
  type     = "STANDARD"

  definition = templatefile("${path.root}/../step-functions/onboarding.asl.json", {
    ListingsTable                  = var.listings_table_name
    EventBusName                   = var.event_bus_name
    FetchInputDataFunctionArn      = var.fetch_input_data_fn_arn
    InvokeVideoAgentFunctionArn    = var.invoke_video_agent_fn_arn
    GenerateDescriptionFunctionArn = var.generate_description_fn_arn
    SubmitForReviewFunctionArn     = var.submit_for_review_fn_arn
    OwnerNotifyTopicArn            = var.owner_notify_topic_arn
    OpsNotifyTopicArn              = var.ops_notify_topic_arn
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  tracing_configuration { enabled = true }
}

output "state_machine_arn" { value = aws_sfn_state_machine.onboarding.arn }
