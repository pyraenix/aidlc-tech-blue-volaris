variable "name_prefix" { type = string }
variable "app_domains" { type = list(string) }
variable "waf_acl_arn" { type = string }

# Two static SPAs (owner + reviewer) on S3 + CloudFront with Origin Access
# Control. Buckets stay private; only CloudFront can read them.
locals {
  apps = ["owner", "reviewer"]
}

resource "aws_s3_bucket" "app" {
  for_each = toset(local.apps)
  bucket   = "${var.name_prefix}-${each.key}-app"
}

resource "aws_s3_bucket_public_access_block" "app" {
  for_each                = aws_s3_bucket.app
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "app" {
  for_each                          = toset(local.apps)
  name                              = "${var.name_prefix}-${each.key}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "app" {
  for_each            = toset(local.apps)
  enabled             = true
  default_root_object = "index.html"
  web_acl_id          = var.waf_acl_arn
  comment             = "${var.name_prefix}-${each.key}"

  origin {
    domain_name              = aws_s3_bucket.app[each.key].bucket_regional_domain_name
    origin_id                = "s3-${each.key}"
    origin_access_control_id = aws_cloudfront_origin_access_control.app[each.key].id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-${each.key}"
    viewer_protocol_policy = "redirect-to-https"
    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }
  }

  # SPA routing — serve index.html on 403/404 so client-side routes work.
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }
  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# Bucket policy: only the matching CloudFront distribution may read.
data "aws_iam_policy_document" "oac" {
  for_each = toset(local.apps)
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.app[each.key].arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.app[each.key].arn]
    }
  }
}

resource "aws_s3_bucket_policy" "app" {
  for_each = toset(local.apps)
  bucket   = aws_s3_bucket.app[each.key].id
  policy   = data.aws_iam_policy_document.oac[each.key].json
}

output "owner_app_bucket" { value = aws_s3_bucket.app["owner"].id }
output "reviewer_app_bucket" { value = aws_s3_bucket.app["reviewer"].id }
output "owner_app_url" { value = "https://${aws_cloudfront_distribution.app["owner"].domain_name}" }
output "reviewer_app_url" { value = "https://${aws_cloudfront_distribution.app["reviewer"].domain_name}" }
