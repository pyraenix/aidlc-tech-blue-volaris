env    = "stage"
region = "eu-west-2"

app_domains = [
  "https://onboard.stage.techblue.example",
  "https://review.stage.techblue.example",
]

# Auth: self-hosted Keycloak (owns login + email-OTP). Replace the issuer and
# audience with your real STAGE Keycloak realm + client. Issuer must be publicly
# reachable so API Gateway can fetch JWKS.
keycloak_issuer        = "https://sso.stage.techblue.example/realms/techblue"
keycloak_audience      = ["property-onboarding"]
keycloak_roles_claim   = "realm_access.roles"
reviewer_approver_role = "listing-approver"
reviewer_editor_role   = "listing-editor"

raw_video_retention_days = 7
max_upload_mb            = 500
bedrock_model_id         = "anthropic.claude-3-5-sonnet-20241022-v2:0"

# REST integrations (native Step Functions HTTP Tasks). Base URLs are config;
# set the API keys via TF_VAR_upstream_data_api_key / TF_VAR_video_agent_api_key
# (do NOT commit keys). They are stored in the EventBridge API Connections.
upstream_data_base_url = "https://data.stage.techblue.example"
video_agent_base_url   = "https://video-agent.stage.techblue.example"

vpc_cidr = "10.20.0.0/16"

waf_rate_limit_per_5min = 2000

log_retention_days = 30
enable_guardduty   = true
