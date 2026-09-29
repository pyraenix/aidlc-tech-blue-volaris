# ===========================================================================
# Identity — self-hosted Keycloak (external to this app).
#
# The wider UK-market ecosystem runs its own self-hosted Keycloak, which owns
# the full login lifecycle including passwordless email-OTP. This component does
# NOT create an identity provider: owners and reviewers authenticate against
# Keycloak directly (OIDC auth-code + PKCE from the SPAs), and this app only
# trusts the JWTs Keycloak issues. API Gateway validates those tokens against
# Keycloak's OIDC issuer / JWKS (see modules/api).
#
# This module is therefore a thin, validated pass-through of the Keycloak
# coordinates the rest of the stack needs. It intentionally provisions no AWS
# resources — there is no Cognito user pool, no SES sender, and no OTP Lambdas.
# ===========================================================================

variable "name_prefix" {
  description = "Resource name prefix (kept for interface consistency with sibling modules; this module creates no named AWS resources)."
  type        = string
}

variable "keycloak_issuer" {
  description = "Keycloak realm OIDC issuer URL, e.g. https://sso.example/realms/<realm>. Must be publicly reachable so the API Gateway JWT authorizer can fetch JWKS."
  type        = string

  validation {
    condition     = can(regex("^https://", var.keycloak_issuer))
    error_message = "keycloak_issuer must be an https:// URL (the realm issuer, e.g. https://sso.example/realms/techblue)."
  }
}

variable "keycloak_audience" {
  description = "Expected 'aud' claim value(s) — the Keycloak client ID(s) this app accepts tokens for."
  type        = list(string)

  validation {
    condition     = length(var.keycloak_audience) > 0
    error_message = "keycloak_audience must contain at least one client ID."
  }
}

variable "keycloak_roles_claim" {
  description = "JWT claim path that carries the reviewer role. For a Keycloak realm role this is typically 'realm_access.roles'; for a client role, 'resource_access.<client>.roles'."
  type        = string
  default     = "realm_access.roles"
}

variable "reviewer_approver_role" {
  description = "Keycloak role that grants approve/reject authority in the reviewer console."
  type        = string
  default     = "listing-approver"
}

variable "reviewer_editor_role" {
  description = "Keycloak role that grants draft-edit (but not final-approve) authority."
  type        = string
  default     = "listing-editor"
}

# --- Pass-through outputs consumed by modules/api + the reviewer SPA config --
output "keycloak_issuer" { value = var.keycloak_issuer }
output "keycloak_audience" { value = var.keycloak_audience }
output "keycloak_roles_claim" { value = var.keycloak_roles_claim }
output "reviewer_approver_role" { value = var.reviewer_approver_role }
output "reviewer_editor_role" { value = var.reviewer_editor_role }
