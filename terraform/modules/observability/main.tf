variable "name_prefix" { type = string }
variable "log_retention_days" { type = number }
variable "enable_guardduty" { type = bool }
variable "state_machine_arn" { type = string }
variable "api_id" { type = string }

# --- Central dashboard ------------------------------------------------------
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.name_prefix}-onboarding"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6,
        properties = {
          title  = "Step Functions executions",
          region = data.aws_region.current.name,
          metrics = [
            ["AWS/States", "ExecutionsSucceeded", "StateMachineArn", var.state_machine_arn],
            ["AWS/States", "ExecutionsFailed", "StateMachineArn", var.state_machine_arn],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6,
        properties = {
          title  = "API 4xx / 5xx",
          region = data.aws_region.current.name,
          metrics = [
            ["AWS/ApiGateway", "4xx", "ApiId", var.api_id],
            ["AWS/ApiGateway", "5xx", "ApiId", var.api_id],
          ]
        }
      }
    ]
  })
}

# --- Alarm: any failed onboarding execution --------------------------------
resource "aws_cloudwatch_metric_alarm" "sfn_failures" {
  alarm_name          = "${var.name_prefix}-onboarding-failures"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 0
  period              = 300
  namespace           = "AWS/States"
  metric_name         = "ExecutionsFailed"
  statistic           = "Sum"
  dimensions          = { StateMachineArn = var.state_machine_arn }
  treat_missing_data  = "notBreaching"
}

# --- GuardDuty --------------------------------------------------------------
resource "aws_guardduty_detector" "main" {
  count  = var.enable_guardduty ? 1 : 0
  enable = true
}

output "dashboard_name" { value = aws_cloudwatch_dashboard.main.dashboard_name }

data "aws_region" "current" {}
