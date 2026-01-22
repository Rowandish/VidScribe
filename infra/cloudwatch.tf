# =============================================================================
# VidScribe - CloudWatch Configuration
# =============================================================================
# Log groups with retention and error alarms for monitoring.
# =============================================================================

# -----------------------------------------------------------------------------
# CloudWatch Log Groups
# One per Lambda with 7-day retention to minimize costs
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "poller" {
  name              = "/aws/lambda/${local.lambda_poller_name}"
  retention_in_days = var.log_retention_days

  tags = {
    Name     = "Poller Lambda Logs"
    Function = "poller"
  }
}

resource "aws_cloudwatch_log_group" "processor" {
  name              = "/aws/lambda/${local.lambda_processor_name}"
  retention_in_days = var.log_retention_days

  tags = {
    Name     = "Processor Lambda Logs"
    Function = "processor"
  }
}

resource "aws_cloudwatch_log_group" "newsletter" {
  name              = "/aws/lambda/${local.lambda_newsletter_name}"
  retention_in_days = var.log_retention_days

  tags = {
    Name     = "Newsletter Lambda Logs"
    Function = "newsletter"
  }
}

# -----------------------------------------------------------------------------
# Metric Filters for Error Detection
# Creates CloudWatch metrics from log patterns
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_metric_filter" "poller_errors" {
  name           = "${local.lambda_poller_name}-errors"
  pattern        = "ERROR"
  log_group_name = aws_cloudwatch_log_group.poller.name

  metric_transformation {
    name          = "PollerErrors"
    namespace     = "VidScribe"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_log_metric_filter" "processor_errors" {
  name           = "${local.lambda_processor_name}-errors"
  pattern        = "ERROR"
  log_group_name = aws_cloudwatch_log_group.processor.name

  metric_transformation {
    name          = "ProcessorErrors"
    namespace     = "VidScribe"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_log_metric_filter" "newsletter_errors" {
  name           = "${local.lambda_newsletter_name}-errors"
  pattern        = "ERROR"
  log_group_name = aws_cloudwatch_log_group.newsletter.name

  metric_transformation {
    name          = "NewsletterErrors"
    namespace     = "VidScribe"
    value         = "1"
    default_value = "0"
  }
}

# -----------------------------------------------------------------------------
# CloudWatch Alarms
# Alert when errors occur
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "poller_errors" {
  alarm_name          = "${local.lambda_poller_name}-error-alarm"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "PollerErrors"
  namespace           = "VidScribe"
  period              = 300 # 5 minutes
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Triggered when the Poller Lambda logs an error"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name     = "Poller Error Alarm"
    Function = "poller"
  }
}

resource "aws_cloudwatch_metric_alarm" "processor_errors" {
  alarm_name          = "${local.lambda_processor_name}-error-alarm"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ProcessorErrors"
  namespace           = "VidScribe"
  period              = 300 # 5 minutes
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Triggered when the Processor Lambda logs an error"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name     = "Processor Error Alarm"
    Function = "processor"
  }
}

resource "aws_cloudwatch_metric_alarm" "newsletter_errors" {
  alarm_name          = "${local.lambda_newsletter_name}-error-alarm"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "NewsletterErrors"
  namespace           = "VidScribe"
  period              = 300 # 5 minutes
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Triggered when the Newsletter Lambda logs an error"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name     = "Newsletter Error Alarm"
    Function = "newsletter"
  }
}

# -----------------------------------------------------------------------------
# DLQ Alarm
# Alert when messages end up in the Dead Letter Queue
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  alarm_name          = "${local.sqs_dlq_queue_name}-alarm"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300 # 5 minutes
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Triggered when messages appear in the Dead Letter Queue"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.video_dlq.name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "DLQ Messages Alarm"
  }
}
