env    = "prod"
region = "eu-west-2"

app_domains = [
  "https://onboard.techblue.example",
  "https://review.techblue.example",
]

otp_email_from                = "no-reply@techblue.example"
otp_code_ttl_seconds          = 300
access_token_validity_minutes = 15

raw_video_retention_days = 90
max_upload_mb            = 500
bedrock_model_id         = "anthropic.claude-3-5-sonnet-20241022-v2:0"

vpc_cidr = "10.30.0.0/16"

waf_rate_limit_per_5min      = 2000
otp_send_rate_limit_per_5min = 60

log_retention_days = 365
enable_guardduty   = true
