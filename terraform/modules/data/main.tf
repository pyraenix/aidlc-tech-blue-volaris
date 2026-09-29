variable "name_prefix" { type = string }

# Durable, queryable store for SUBMITTED listings + their lifecycle state.
# Single-table design. byStatus GSI drives the reviewer queue.
resource "aws_dynamodb_table" "listings" {
  name         = "${var.name_prefix}-listings"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  attribute {
    name = "PK"
    type = "S"
  }
  attribute {
    name = "SK"
    type = "S"
  }
  attribute {
    name = "status"
    type = "S"
  }
  attribute {
    name = "ownerId"
    type = "S"
  }

  global_secondary_index {
    name            = "byStatus"
    hash_key        = "status"
    range_key       = "SK"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "byOwner"
    hash_key        = "ownerId"
    range_key       = "SK"
    projection_type = "ALL"
  }

  point_in_time_recovery { enabled = true }
  server_side_encryption { enabled = true }

  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"
}

output "listings_table_name" { value = aws_dynamodb_table.listings.name }
output "listings_table_arn" { value = aws_dynamodb_table.listings.arn }
