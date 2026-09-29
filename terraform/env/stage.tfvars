env    = "stage"
region = "eu-west-2"

app_domains = [
  "https://onboard.stage.techblue.example",
  "https://review.stage.techblue.example",
]

otp_email_from                = "no-reply@stage.techblue.example"
otp_code_ttl_seconds          = 300
access_token_validity_minutes = 15

raw_video_retention_days = 7
max_upload_mb            = 500
bedrock_model_id         = "anthropic.claude-3-5-sonnet-20241022-v2:0"

vpc_cidr = "10.20.0.0/16"

waf_rate_limit_per_5min      = 2000
otp_send_rate_limit_per_5min = 100

log_retention_days = 30
enable_guardduty   = true
