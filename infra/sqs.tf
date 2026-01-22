# =============================================================================
# VidScribe - SQS Configuration
# =============================================================================
# Main queue for video processing with Dead Letter Queue for failed messages.
# =============================================================================

# -----------------------------------------------------------------------------
# Dead Letter Queue (DLQ)
# Receives messages that fail processing after max attempts
# -----------------------------------------------------------------------------

resource "aws_sqs_queue" "video_dlq" {
  name = local.sqs_dlq_queue_name

  # Keep failed messages for 14 days for debugging
  message_retention_seconds = 1209600 # 14 days

  # Enable server-side encryption
  sqs_managed_sse_enabled = true

  tags = {
    Name        = "VidScribe Video Processing DLQ"
    Description = "Dead letter queue for failed video processing"
  }
}

# -----------------------------------------------------------------------------
# Main Video Processing Queue
# Receives new video IDs from the Poller Lambda
# -----------------------------------------------------------------------------

resource "aws_sqs_queue" "video_queue" {
  name = local.sqs_queue_name

  # Visibility timeout should be 6x the Lambda timeout
  # This ensures the message isn't reprocessed while Lambda is still working
  visibility_timeout_seconds = local.sqs_visibility_timeout

  # Message retention: 4 days (allows for weekend/holiday recovery)
  message_retention_seconds = var.sqs_message_retention_seconds

  # Delay before message becomes visible (0 = immediately)
  delay_seconds = 0

  # Maximum message size (256 KB is the max)
  max_message_size = 262144

  # Long polling to reduce empty receives and API calls
  receive_wait_time_seconds = 20

  # Enable server-side encryption
  sqs_managed_sse_enabled = true

  # Configure Dead Letter Queue
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.video_dlq.arn
    maxReceiveCount     = var.sqs_max_receive_count
  })

  tags = {
    Name        = "VidScribe Video Processing Queue"
    Description = "Queue for new videos to be processed"
  }
}

# -----------------------------------------------------------------------------
# DLQ Redrive Allow Policy
# Allows the main queue to send messages to the DLQ
# -----------------------------------------------------------------------------

resource "aws_sqs_queue_redrive_allow_policy" "video_dlq" {
  queue_url = aws_sqs_queue.video_dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.video_queue.arn]
  })
}
