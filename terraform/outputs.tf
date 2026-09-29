output "region" { value = var.region }
output "environment" { value = var.env }

# --- Auth (self-hosted Keycloak) --------------------------------------------
output "keycloak_issuer" { value = module.identity.keycloak_issuer }
output "keycloak_audience" { value = module.identity.keycloak_audience }
output "reviewer_approver_role" { value = module.identity.reviewer_approver_role }
output "reviewer_editor_role" { value = module.identity.reviewer_editor_role }

# --- API --------------------------------------------------------------------
output "api_base_url" { value = module.api.api_base_url }

# --- Frontend ---------------------------------------------------------------
output "owner_app_url" { value = module.frontend.owner_app_url }
output "reviewer_app_url" { value = module.frontend.reviewer_app_url }
output "owner_app_bucket" { value = module.frontend.owner_app_bucket }
output "reviewer_app_bucket" { value = module.frontend.reviewer_app_bucket }

# --- Storage / state --------------------------------------------------------
output "raw_videos_bucket" { value = module.storage.raw_videos_bucket_name }
output "frames_bucket" { value = module.storage.frames_bucket_name }
output "listings_table" { value = module.data.listings_table_name }
output "redis_endpoint" { value = module.cache.redis_endpoint }

# --- Orchestration ----------------------------------------------------------
output "state_machine_arn" { value = module.workflow.state_machine_arn }
output "event_bus_name" { value = module.events.event_bus_name }

# --- Publish ----------------------------------------------------------------
output "publish_dlq_url" { value = module.publish.publish_dlq_url }

# --- Integration ------------------------------------------------------------
# The publishing app still uses a Secrets Manager secret (populate base URL +
# apiKey before use). The upstream data app + video agent authenticate via
# EventBridge API Connections instead (their API keys are set at apply time via
# TF_VAR_upstream_data_api_key / TF_VAR_video_agent_api_key).
output "publish_app_secret_arn" { value = module.integration.publish_app_secret_arn }

output "integration_connections" {
  value = {
    upstream_data = module.integration.upstream_data_connection_arn
    video_agent   = module.integration.video_agent_connection_arn
  }
}
