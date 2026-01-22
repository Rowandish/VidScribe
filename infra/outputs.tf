# =============================================================================
# VidScribe - Terraform Outputs
# =============================================================================

# -----------------------------------------------------------------------------
# Lambda Functions
# -----------------------------------------------------------------------------

output "lambda_poller_arn" {
  description = "ARN of the Poller Lambda function"
  value       = aws_lambda_function.poller.arn
}

output "lambda_poller_name" {
  description = "Name of the Poller Lambda function"
  value       = aws_lambda_function.poller.function_name
}

output "lambda_processor_arn" {
  description = "ARN of the Processor Lambda function"
  value       = aws_lambda_function.processor.arn
}

output "lambda_processor_name" {
  description = "Name of the Processor Lambda function"
  value       = aws_lambda_function.processor.function_name
}

output "lambda_newsletter_arn" {
  description = "ARN of the Newsletter Lambda function"
  value       = aws_lambda_function.newsletter.arn
}

output "lambda_newsletter_name" {
  description = "Name of the Newsletter Lambda function"
  value       = aws_lambda_function.newsletter.function_name
}

# -----------------------------------------------------------------------------
# DynamoDB
# -----------------------------------------------------------------------------

output "dynamodb_table_name" {
  description = "Name of the DynamoDB table"
  value       = aws_dynamodb_table.videos.name
}

output "dynamodb_table_arn" {
  description = "ARN of the DynamoDB table"
  value       = aws_dynamodb_table.videos.arn
}

# -----------------------------------------------------------------------------
# SQS
# -----------------------------------------------------------------------------

output "sqs_queue_url" {
  description = "URL of the main SQS queue"
  value       = aws_sqs_queue.video_queue.url
}

output "sqs_dlq_url" {
  description = "URL of the Dead Letter Queue"
  value       = aws_sqs_queue.video_dlq.url
}

# -----------------------------------------------------------------------------
# SSM Parameters
# -----------------------------------------------------------------------------

output "ssm_youtube_channels_path" {
  description = "SSM parameter path for YouTube channels configuration"
  value       = aws_ssm_parameter.youtube_channels.name
}

output "ssm_llm_config_path" {
  description = "SSM parameter path for LLM configuration"
  value       = aws_ssm_parameter.llm_config.name
}

# -----------------------------------------------------------------------------
# CloudWatch
# -----------------------------------------------------------------------------

output "cloudwatch_log_group_poller" {
  description = "CloudWatch Log Group for Poller Lambda"
  value       = aws_cloudwatch_log_group.poller.name
}

output "cloudwatch_log_group_processor" {
  description = "CloudWatch Log Group for Processor Lambda"
  value       = aws_cloudwatch_log_group.processor.name
}

output "cloudwatch_log_group_newsletter" {
  description = "CloudWatch Log Group for Newsletter Lambda"
  value       = aws_cloudwatch_log_group.newsletter.name
}

# -----------------------------------------------------------------------------
# SNS
# -----------------------------------------------------------------------------

output "sns_alerts_topic_arn" {
  description = "ARN of the SNS topic for alerts"
  value       = aws_sns_topic.alerts.arn
}

# -----------------------------------------------------------------------------
# Useful Commands
# -----------------------------------------------------------------------------

output "test_commands" {
  description = "Useful commands for testing the deployment"
  value       = <<-EOT
    
    # Manually invoke the Poller Lambda:
    aws lambda invoke --function-name ${aws_lambda_function.poller.function_name} output.json && cat output.json
    
    # Check SQS queue for messages:
    aws sqs get-queue-attributes --queue-url ${aws_sqs_queue.video_queue.url} --attribute-names ApproximateNumberOfMessages
    
    # View recent logs for Poller:
    aws logs tail ${aws_cloudwatch_log_group.poller.name} --follow
    
    # Update YouTube channels list:
    aws ssm put-parameter --name "${aws_ssm_parameter.youtube_channels.name}" --value '["CHANNEL_ID_1","CHANNEL_ID_2"]' --type String --overwrite
    
  EOT
}
