# =============================================================================
# VidScribe - EventBridge Configuration
# =============================================================================
# Scheduled triggers for the Poller and Newsletter Lambdas.
# =============================================================================

# -----------------------------------------------------------------------------
# Poller Schedule (Every 12 hours)
# Checks for new videos on monitored YouTube channels
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "poller_schedule" {
  name                = "${local.lambda_poller_name}-schedule"
  description         = "Triggers the Poller Lambda every 12 hours to check for new videos"
  schedule_expression = var.poller_schedule

  tags = {
    Name     = "Poller Schedule"
    Function = "poller"
  }
}

resource "aws_cloudwatch_event_target" "poller" {
  rule      = aws_cloudwatch_event_rule.poller_schedule.name
  target_id = "PollerLambda"
  arn       = aws_lambda_function.poller.arn
}

resource "aws_lambda_permission" "poller_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.poller.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.poller_schedule.arn
}

# -----------------------------------------------------------------------------
# Newsletter Schedule (Every Saturday at 09:00 UTC)
# Sends weekly digest of video summaries
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "newsletter_schedule" {
  name                = "${local.lambda_newsletter_name}-schedule"
  description         = "Triggers the Newsletter Lambda every Saturday at 09:00 UTC"
  schedule_expression = var.newsletter_schedule

  tags = {
    Name     = "Newsletter Schedule"
    Function = "newsletter"
  }
}

resource "aws_cloudwatch_event_target" "newsletter" {
  rule      = aws_cloudwatch_event_rule.newsletter_schedule.name
  target_id = "NewsletterLambda"
  arn       = aws_lambda_function.newsletter.arn
}

resource "aws_lambda_permission" "newsletter_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.newsletter.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.newsletter_schedule.arn
}

# -----------------------------------------------------------------------------
# Cleanup Schedule (1st of each month at 03:00 UTC)
# Removes permanently failed records from DynamoDB
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "cleanup_schedule" {
  name                = "${local.lambda_cleanup_name}-schedule"
  description         = "Triggers the Cleanup Lambda on the 1st of each month at 03:00 UTC"
  schedule_expression = "cron(0 3 1 * ? *)"

  tags = {
    Name     = "Cleanup Schedule"
    Function = "cleanup"
  }
}

resource "aws_cloudwatch_event_target" "cleanup" {
  rule      = aws_cloudwatch_event_rule.cleanup_schedule.name
  target_id = "CleanupLambda"
  arn       = aws_lambda_function.cleanup.arn
}

resource "aws_lambda_permission" "cleanup_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cleanup.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.cleanup_schedule.arn
}
