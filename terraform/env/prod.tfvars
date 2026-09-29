env    = "prod"
region = "eu-west-2"

app_domains = [
  "https://onboard.techblue.example",
  "https://review.techblue.example",
]

# Auth: self-hosted Keycloak (owns login + email-OTP). Replace the issuer and
# audience with your real PROD Keycloak realm + client. Issuer must be publicly
# reachable so API Gateway can fetch JWKS.
keycloak_issuer        = "https://sso.techblue.example/realms/techblue"
keycloak_audience      = ["property-onboarding"]
keycloak_roles_claim   = "realm_access.roles"
reviewer_approver_role = "listing-approver"
reviewer_editor_role   = "listing-editor"

raw_video_retention_days = 90
max_upload_mb            = 500
bedrock_model_id         = "anthropic.claude-3-5-sonnet-20241022-v2:0"

# REST integrations (native Step Functions HTTP Tasks). Base URLs are config;
# set the API keys via TF_VAR_upstream_data_api_key / TF_VAR_video_agent_api_key
# (do NOT commit keys). They are stored in the EventBridge API Connections.
upstream_data_base_url = "https://data.techblue.example"
video_agent_base_url   = "https://video-agent.techblue.example"

vpc_cidr = "10.30.0.0/16"

waf_rate_limit_per_5min = 2000

log_retention_days = 365
enable_guardduty   = true
