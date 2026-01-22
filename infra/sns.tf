# =============================================================================
# VidScribe - SNS Configuration
# =============================================================================
# SNS topic for error notifications via email.
# =============================================================================

# -----------------------------------------------------------------------------
# SNS Topic for Alerts
# -----------------------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-alerts"

  tags = {
    Name        = "VidScribe Alerts Topic"
    Description = "Receives alert notifications from CloudWatch alarms"
  }
}

# -----------------------------------------------------------------------------
# Email Subscription for Admin
# Note: The admin will need to confirm the subscription via email
# -----------------------------------------------------------------------------

resource "aws_sns_topic_subscription" "admin_email" {
  count     = var.admin_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.admin_email
}

# -----------------------------------------------------------------------------
# SNS Topic Policy
# Allow CloudWatch to publish to this topic
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "sns_alerts_policy" {
  statement {
    sid    = "AllowCloudWatchAlarms"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudwatch:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:alarm:*"]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.sns_alerts_policy.json
}
