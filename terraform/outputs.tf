output "region" { value = var.region }
output "environment" { value = var.env }

# --- Auth -------------------------------------------------------------------
output "cognito_user_pool_id" { value = module.identity.user_pool_id }
output "cognito_user_pool_client_id" { value = module.identity.user_pool_client_id }

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

# --- Integration secrets to populate (set base URL + apiKey before use) -----
output "integration_secrets" {
  value = {
    video_agent = module.integration.video_agent_secret_arn
    input_data  = module.integration.input_data_secret_arn
    publish_app = module.integration.publish_app_secret_arn
  }
}
