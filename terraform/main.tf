# ---------------------------------------------------------------------------
# Root module — wires every module together. Read top-to-bottom, it follows
# the request path: network -> security -> identity -> storage/cache/data ->
# api -> processing -> workflow -> events -> publish -> frontend -> observability.
# ---------------------------------------------------------------------------

locals {
  name_prefix = "${var.project}-${var.env}"
}

# --- Foundation -------------------------------------------------------------
module "network" {
  source      = "./modules/network"
  name_prefix = local.name_prefix
  vpc_cidr    = var.vpc_cidr
}

module "security" {
  source                  = "./modules/security"
  name_prefix             = local.name_prefix
  waf_rate_limit_per_5min = var.waf_rate_limit_per_5min
  providers = {
    aws.use1 = aws.use1
  }
}

# --- Identity (self-hosted Keycloak, external — email-OTP owned by Keycloak) -
module "identity" {
  source                 = "./modules/identity"
  name_prefix            = local.name_prefix
  keycloak_issuer        = var.keycloak_issuer
  keycloak_audience      = var.keycloak_audience
  keycloak_roles_claim   = var.keycloak_roles_claim
  reviewer_approver_role = var.reviewer_approver_role
  reviewer_editor_role   = var.reviewer_editor_role
}

# --- State: durable (DynamoDB) + ephemeral draft (Redis) --------------------
module "storage" {
  source                   = "./modules/storage"
  name_prefix              = local.name_prefix
  raw_video_retention_days = var.raw_video_retention_days
  app_domains              = var.app_domains
}

module "cache" {
  source             = "./modules/cache"
  name_prefix        = local.name_prefix
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids
  lambda_sg_id       = module.network.lambda_sg_id
}

module "data" {
  source      = "./modules/data"
  name_prefix = local.name_prefix
}

# --- API edge (API Gateway + Keycloak JWT authorizer + presign) -------------
module "api" {
  source              = "./modules/api"
  name_prefix         = local.name_prefix
  app_domains         = var.app_domains
  keycloak_issuer     = module.identity.keycloak_issuer
  keycloak_audience   = module.identity.keycloak_audience
  raw_videos_bucket   = module.storage.raw_videos_bucket_name
  max_upload_mb       = var.max_upload_mb
  listings_table_arn  = module.data.listings_table_arn
  listings_table_name = module.data.listings_table_name
  redis_endpoint      = module.cache.redis_endpoint
  vpc_subnet_ids      = module.network.private_subnet_ids
  lambda_sg_id        = module.network.lambda_sg_id
  waf_acl_arn         = module.security.regional_waf_acl_arn
}

# --- Integration layer (in-house video agent + upstream data + Bedrock) -----
module "integration" {
  source             = "./modules/integration"
  name_prefix        = local.name_prefix
  frames_bucket      = module.storage.frames_bucket_arn
  frames_bucket_name = module.storage.frames_bucket_name
  bedrock_model_id   = var.bedrock_model_id
  region             = var.region

  # REST integrations: base URLs are config, API keys go into the connections.
  upstream_data_base_url = var.upstream_data_base_url
  upstream_data_api_key  = var.upstream_data_api_key
  video_agent_base_url   = var.video_agent_base_url
  video_agent_api_key    = var.video_agent_api_key
}

# --- Orchestration (Step Functions HITL) ------------------------------------
module "workflow" {
  source                      = "./modules/workflow"
  name_prefix                 = local.name_prefix
  listings_table_name         = module.data.listings_table_name
  listings_table_arn          = module.data.listings_table_arn
  event_bus_name              = module.events.event_bus_name
  event_bus_arn               = module.events.event_bus_arn
  generate_description_fn_arn = module.integration.generate_description_fn_arn
  submit_for_review_fn_arn    = module.api.submit_for_review_fn_arn
  owner_notify_topic_arn      = module.events.owner_notify_topic_arn
  ops_notify_topic_arn        = module.events.ops_notify_topic_arn

  # Native HTTP Task integrations (connections + endpoints).
  upstream_data_base_url              = var.upstream_data_base_url
  upstream_data_connection_arn        = module.integration.upstream_data_connection_arn
  upstream_data_connection_secret_arn = module.integration.upstream_data_connection_secret_arn
  video_agent_base_url                = var.video_agent_base_url
  video_agent_connection_arn          = module.integration.video_agent_connection_arn
  video_agent_connection_secret_arn   = module.integration.video_agent_connection_secret_arn
}

# --- Event bus + notifications + S3->SFN trigger ----------------------------
module "events" {
  source                 = "./modules/events"
  name_prefix            = local.name_prefix
  raw_videos_bucket_name = module.storage.raw_videos_bucket_name
  state_machine_arn      = module.workflow.state_machine_arn
}

# --- Publish: hand off approved listing to the existing publishing app -------
module "publish" {
  source                  = "./modules/publish"
  name_prefix             = local.name_prefix
  event_bus_name          = module.events.event_bus_name
  event_bus_arn           = module.events.event_bus_arn
  listings_table_arn      = module.data.listings_table_arn
  listings_table_name     = module.data.listings_table_name
  publish_app_secret_arn  = module.integration.publish_app_secret_arn
  publish_app_secret_name = "${local.name_prefix}-integration-publish-app"
}

# --- Frontend hosting (S3 + CloudFront, owner + reviewer SPAs) ---------------
module "frontend" {
  source      = "./modules/frontend"
  name_prefix = local.name_prefix
  app_domains = var.app_domains
  waf_acl_arn = module.security.cloudfront_waf_acl_arn
}

# --- Observability ----------------------------------------------------------
module "observability" {
  source             = "./modules/observability"
  name_prefix        = local.name_prefix
  log_retention_days = var.log_retention_days
  enable_guardduty   = var.enable_guardduty
  state_machine_arn  = module.workflow.state_machine_arn
  api_id             = module.api.api_id
}
