variable "name_prefix" { type = string }
variable "raw_videos_bucket_name" { type = string }
variable "state_machine_arn" { type = string }

# Dedicated bus keeps onboarding events off the default bus.
resource "aws_cloudwatch_event_bus" "main" {
  name = "${var.name_prefix}-bus"
}

# --- SNS topics -------------------------------------------------------------
resource "aws_sns_topic" "owner_notify" { name = "${var.name_prefix}-owner-notify" }
resource "aws_sns_topic" "ops_notify" { name = "${var.name_prefix}-ops-notify" }

# --- Rule: raw video landed in S3 -> start the state machine ----------------
resource "aws_cloudwatch_event_rule" "video_uploaded" {
  name           = "${var.name_prefix}-video-uploaded"
  event_bus_name = "default" # S3 "Object Created" events land on the DEFAULT bus
  description    = "Fires when a new object is created in the raw-videos bucket."
  event_pattern = jsonencode({
    source        = ["aws.s3"]
    "detail-type" = ["Object Created"]
    detail        = { bucket = { name = [var.raw_videos_bucket_name] } }
  })
}

data "aws_iam_policy_document" "eb_invoke_sfn_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eb_invoke_sfn" {
  name               = "${var.name_prefix}-eb-invoke-sfn"
  assume_role_policy = data.aws_iam_policy_document.eb_invoke_sfn_assume.json
}

resource "aws_iam_role_policy" "eb_invoke_sfn" {
  name = "${var.name_prefix}-eb-invoke-sfn"
  role = aws_iam_role.eb_invoke_sfn.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = ["states:StartExecution"], Resource = var.state_machine_arn }]
  })
}

# Transform the S3 event into the state machine's expected input shape.
resource "aws_cloudwatch_event_target" "start_sfn" {
  rule      = aws_cloudwatch_event_rule.video_uploaded.name
  target_id = "start-onboarding"
  arn       = var.state_machine_arn
  role_arn  = aws_iam_role.eb_invoke_sfn.arn

  input_transformer {
    input_paths = {
      key    = "$.detail.object.key"
      bucket = "$.detail.bucket.name"
    }
    # The uploaded key is expected to be "listings/<listingId>/raw/<file>".
    input_template = <<-EOT
      {
        "listingId": <key>,
        "rawVideoKey": <key>,
        "rawBucket": <bucket>
      }
    EOT
  }
}

# --- Bus for the app's own ListingApproved event ----------------------------
resource "aws_cloudwatch_event_rule" "listing_approved" {
  name           = "${var.name_prefix}-listing-approved"
  event_bus_name = aws_cloudwatch_event_bus.main.name
  description    = "Fires when a reviewer approves a listing."
  event_pattern = jsonencode({
    source        = ["techblue.onboarding"]
    "detail-type" = ["ListingApproved"]
  })
}

output "event_bus_name" { value = aws_cloudwatch_event_bus.main.name }
output "event_bus_arn" { value = aws_cloudwatch_event_bus.main.arn }
output "listing_approved_rule" { value = aws_cloudwatch_event_rule.listing_approved.name }
output "owner_notify_topic_arn" { value = aws_sns_topic.owner_notify.arn }
output "ops_notify_topic_arn" { value = aws_sns_topic.ops_notify.arn }
