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

# --- Auth (Cognito email-OTP) ----------------------------------------------
variable "otp_email_from" {
  description = "Verified SES sender address used to email the 6-digit code."
  type        = string
}

variable "otp_code_ttl_seconds" {
  description = "How long a 6-digit code stays valid."
  type        = number
  default     = 300
}

variable "access_token_validity_minutes" {
  description = "Cognito access-token lifetime."
  type        = number
  default     = 15
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

variable "otp_send_rate_limit_per_5min" {
  description = "Tighter WAF rate limit for the unauthenticated OTP-request route."
  type        = number
  default     = 100
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
