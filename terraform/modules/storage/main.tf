variable "name_prefix" { type = string }
variable "raw_video_retention_days" { type = number }
variable "app_domains" { type = list(string) }

# --- KMS key for at-rest encryption of buckets ------------------------------
resource "aws_kms_key" "s3" {
  description             = "${var.name_prefix} S3 encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "s3" {
  name          = "alias/${var.name_prefix}-s3"
  target_key_id = aws_kms_key.s3.key_id
}

# --- Raw video uploads ------------------------------------------------------
resource "aws_s3_bucket" "raw_videos" {
  bucket = "${var.name_prefix}-raw-videos"
}

resource "aws_s3_bucket_public_access_block" "raw_videos" {
  bucket                  = aws_s3_bucket.raw_videos.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "raw_videos" {
  bucket = aws_s3_bucket.raw_videos.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.s3.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_notification" "raw_videos" {
  bucket      = aws_s3_bucket.raw_videos.id
  eventbridge = true
}

resource "aws_s3_bucket_lifecycle_configuration" "raw_videos" {
  bucket = aws_s3_bucket.raw_videos.id
  rule {
    id     = "expire-raw"
    status = "Enabled"
    filter {}
    expiration { days = var.raw_video_retention_days }
  }
}

# CORS locked to the app domains (never "*" — see decision log DL-09).
resource "aws_s3_bucket_cors_configuration" "raw_videos" {
  bucket = aws_s3_bucket.raw_videos.id
  cors_rule {
    allowed_methods = ["PUT"]
    allowed_origins = var.app_domains
    allowed_headers = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

# --- Extracted frames / snapshots -------------------------------------------
resource "aws_s3_bucket" "frames" {
  bucket = "${var.name_prefix}-frames"
}

resource "aws_s3_bucket_public_access_block" "frames" {
  bucket                  = aws_s3_bucket.frames.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "frames" {
  bucket = aws_s3_bucket.frames.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.s3.arn
    }
    bucket_key_enabled = true
  }
}

output "raw_videos_bucket_name" { value = aws_s3_bucket.raw_videos.id }
output "raw_videos_bucket_arn" { value = aws_s3_bucket.raw_videos.arn }
output "frames_bucket_name" { value = aws_s3_bucket.frames.id }
output "frames_bucket_arn" { value = aws_s3_bucket.frames.arn }
output "kms_key_arn" { value = aws_kms_key.s3.arn }
