# =============================================================================
# VidScribe - Local Values
# =============================================================================

locals {
  # Resource naming prefix
  name_prefix = "${var.project_name}-${var.environment}"

  # Common tags applied to all resources
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    Repository  = "https://github.com/yourusername/VidScribe"
  }

  # Lambda function names
  lambda_poller_name     = "${local.name_prefix}-poller"
  lambda_processor_name  = "${local.name_prefix}-processor"
  lambda_newsletter_name = "${local.name_prefix}-newsletter"

  # SQS visibility timeout should be 6x the processor Lambda timeout
  sqs_visibility_timeout = var.processor_timeout * 6

  # DynamoDB table name
  dynamodb_table_name = "${local.name_prefix}-videos"

  # SQS queue names
  sqs_queue_name     = "${local.name_prefix}-video-queue"
  sqs_dlq_queue_name = "${local.name_prefix}-video-dlq"

  # SSM parameter paths
  ssm_prefix = "/${var.project_name}"

  # LLM configuration object for SSM
  llm_config = jsonencode({
    provider = var.llm_provider
    model    = var.llm_model
    language = var.summarization_language
  })

  # Calculate TTL timestamp (used for DynamoDB records)
  ttl_seconds = var.dynamodb_ttl_days * 24 * 60 * 60
}
