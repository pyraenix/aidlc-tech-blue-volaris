# ---------------------------------------------------------------------------
# Global inputs. Values that DIFFER between stage and prod live in
# env/<env>.tfvars. Anything with a sane default can be overridden there.
# ---------------------------------------------------------------------------

variable "project" {
  description = "Project name, used as a resource name prefix."
  type        = string
  default     = "techblue"
}

variable "env" {
  description = "Environment name (stage | prod). Drives resource naming + isolation."
  type        = string
  validation {
    condition     = contains(["dev", "stage", "prod"], var.env)
    error_message = "env must be one of: dev, stage, prod."
  }
}

variable "region" {
  description = "AWS region to deploy into (UK market -> eu-west-2 London)."
  type        = string
  default     = "eu-west-2"
}

variable "owner_tag" {
  description = "Team/owner tag applied to all resources."
  type        = string
  default     = "techblue-platform"
}

# --- Frontend / CORS --------------------------------------------------------
variable "app_domains" {
  description = "Allowed browser origins for CORS + CloudFront (owner + reviewer apps). Lock this down per env — never '*' in prod."
  type        = list(string)
}

# --- Auth (self-hosted Keycloak) -------------------------------------------
# The ecosystem's own Keycloak owns login, including passwordless email-OTP.
# This app only validates the JWTs Keycloak issues. Set these per environment.
variable "keycloak_issuer" {
  description = "Keycloak realm OIDC issuer URL, e.g. https://sso.example/realms/<realm>. Must be publicly reachable so API Gateway can fetch JWKS."
  type        = string
}

variable "keycloak_audience" {
  description = "Expected 'aud' claim value(s) — the Keycloak client ID(s) tokens are accepted for."
  type        = list(string)
}

variable "keycloak_roles_claim" {
  description = "JWT claim path carrying reviewer roles ('realm_access.roles' for realm roles, or 'resource_access.<client>.roles' for client roles)."
  type        = string
  default     = "realm_access.roles"
}

variable "reviewer_approver_role" {
  description = "Keycloak role granting approve/reject authority in the reviewer console."
  type        = string
  default     = "listing-approver"
}

variable "reviewer_editor_role" {
  description = "Keycloak role granting draft-edit (not final-approve) authority."
  type        = string
  default     = "listing-editor"
}

# --- Video / processing -----------------------------------------------------
variable "raw_video_retention_days" {
  description = "Lifecycle expiry for raw uploaded videos."
  type        = number
  default     = 30
}

variable "max_upload_mb" {
  description = "Hard cap on presigned upload size (MB)."
  type        = number
  default     = 500
}

variable "bedrock_model_id" {
  description = "Bedrock model id for description generation (vision-capable)."
  type        = string
  default     = "anthropic.claude-3-5-sonnet-20241022-v2:0"
}

# --- REST integrations (native Step Functions HTTP Tasks) -------------------
# Base URLs are non-secret config. The API keys are sensitive and are stored in
# EventBridge API Connections (connection-managed Secrets Manager secret),
# injected as the x-api-key header by the HTTP Task — never baked into the
# state-machine definition. Prefer passing the keys via TF_VAR_* env vars or a
# secure tfvars rather than committing them.
variable "upstream_data_base_url" {
  description = "Base URL of the upstream EPC/compliance data app, e.g. https://data.example."
  type        = string
}

variable "upstream_data_api_key" {
  description = "API key for the upstream data app (stored in its API Connection)."
  type        = string
  sensitive   = true
}

variable "video_agent_base_url" {
  description = "Base URL of TechBlue's in-house video->image agent, e.g. https://video-agent.example."
  type        = string
}

variable "video_agent_api_key" {
  description = "API key for the video agent (stored in its API Connection)."
  type        = string
  sensitive   = true
}

# --- Networking (ElastiCache lives in a VPC) --------------------------------
variable "vpc_cidr" {
  description = "CIDR for the platform VPC."
  type        = string
  default     = "10.20.0.0/16"
}

# --- WAF --------------------------------------------------------------------
variable "waf_rate_limit_per_5min" {
  description = "AWS WAF rate-based rule threshold (requests / 5 min / IP)."
  type        = number
  default     = 2000
}

# --- Publishing partners ----------------------------------------------------
# --- Observability ----------------------------------------------------------
variable "log_retention_days" {
  description = "CloudWatch log retention."
  type        = number
  default     = 90
}

variable "enable_guardduty" {
  description = "Enable GuardDuty in this account/env."
  type        = bool
  default     = true
}
