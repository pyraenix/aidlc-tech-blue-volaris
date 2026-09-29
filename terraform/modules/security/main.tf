variable "name_prefix" { type = string }
variable "waf_rate_limit_per_5min" { type = number }
variable "otp_send_rate_limit_per_5min" { type = number }

# ===========================================================================
# Two WAF ACLs are required because scope differs:
#   - CLOUDFRONT scope  (must be created in us-east-1) -> protects the SPAs.
#   - REGIONAL scope    -> protects the regional API Gateway.
# ===========================================================================

# --- Regional WAF for API Gateway ------------------------------------------
resource "aws_wafv2_web_acl" "regional" {
  name        = "${var.name_prefix}-api-waf"
  description = "Protects the onboarding API (regional)."
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # AWS managed common rule set (SQLi, generic bad inputs).
  rule {
    name     = "AWSManagedCommon"
    priority = 1
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-common"
      sampled_requests_enabled   = true
    }
  }

  # Known bad IP reputation list.
  rule {
    name     = "AWSManagedIPReputation"
    priority = 2
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-iprep"
      sampled_requests_enabled   = true
    }
  }

  # Global rate limit per IP across the whole API.
  rule {
    name     = "GlobalRateLimit"
    priority = 3
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit_per_5min
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-ratelimit"
      sampled_requests_enabled   = true
    }
  }

  # Tight rate limit for the unauthenticated OTP-request path (anti brute-force
  # / anti mail-flood). Scoped to the /auth/request-otp URI.
  rule {
    name     = "OtpRequestRateLimit"
    priority = 4
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = var.otp_send_rate_limit_per_5min
        aggregate_key_type = "IP"
        scope_down_statement {
          byte_match_statement {
            search_string         = "/auth/request-otp"
            positional_constraint = "STARTS_WITH"
            field_to_match {
              uri_path {}
            }
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-otp-ratelimit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name_prefix}-api-waf"
    sampled_requests_enabled   = true
  }
}

# --- CloudFront WAF (SPAs) --------------------------------------------------
resource "aws_wafv2_web_acl" "cloudfront" {
  provider    = aws.use1
  name        = "${var.name_prefix}-cf-waf"
  description = "Protects the owner + reviewer SPAs (CloudFront)."
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "AWSManagedCommon"
    priority = 1
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-cf-common"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name_prefix}-cf-waf"
    sampled_requests_enabled   = true
  }
}

output "regional_waf_acl_arn" { value = aws_wafv2_web_acl.regional.arn }
output "cloudfront_waf_acl_arn" { value = aws_wafv2_web_acl.cloudfront.arn }
