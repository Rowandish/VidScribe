# =============================================================================
# VidScribe - DynamoDB Configuration
# =============================================================================
# Single-table design for storing video metadata and summaries.
# Uses composite keys (pk/sk) for flexible querying.
# =============================================================================

resource "aws_dynamodb_table" "videos" {
  name         = local.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST" # On-demand capacity, Free Tier friendly

  # Composite key design:
  # pk: Primary identifier (e.g., "VIDEO#<video_id>" or "CHANNEL#<channel_id>")
  # sk: Sort key for different record types (e.g., "METADATA", "SUMMARY", "PROCESSED")
  hash_key  = "pk"
  range_key = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  # GSI for querying summaries by date (for newsletter)
  attribute {
    name = "gsi1pk"
    type = "S"
  }

  attribute {
    name = "gsi1sk"
    type = "S"
  }

  # Global Secondary Index for querying recent summaries
  # gsi1pk: "SUMMARY"
  # gsi1sk: ISO timestamp for range queries
  global_secondary_index {
    name            = "GSI1"
    hash_key        = "gsi1pk"
    range_key       = "gsi1sk"
    projection_type = "ALL"
  }

  # TTL for automatic cleanup of old records
  ttl {
    enabled        = true
    attribute_name = "ttl"
  }

  # Point-in-time recovery for data protection (optional, but recommended)
  point_in_time_recovery {
    enabled = false # Set to true for production if needed (adds cost)
  }

  tags = {
    Name        = "VidScribe Videos Table"
    Description = "Stores video metadata and AI-generated summaries"
  }
}
