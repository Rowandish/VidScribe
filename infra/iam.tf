# =============================================================================
# VidScribe - IAM Roles and Policies
# =============================================================================
# Implements least privilege principle with dedicated roles for each Lambda.
# =============================================================================

# -----------------------------------------------------------------------------
# Data Sources
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Common assume role policy for Lambda
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# =============================================================================
# POLLER LAMBDA IAM
# =============================================================================

resource "aws_iam_role" "poller" {
  name               = "${local.lambda_poller_name}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = {
    Name = "Poller Lambda Role"
  }
}

data "aws_iam_policy_document" "poller" {
  # CloudWatch Logs - write logs
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = [
      "${aws_cloudwatch_log_group.poller.arn}:*"
    ]
  }

  # SSM Parameter Store - read configuration
  statement {
    sid    = "SSMReadConfig"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath"
    ]
    resources = [
      "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_prefix}/*"
    ]
  }

  # DynamoDB - read/write for deduplication
  statement {
    sid    = "DynamoDBReadWrite"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:Query",
      "dynamodb:Scan",
      "dynamodb:BatchWriteItem"
    ]
    resources = [
      aws_dynamodb_table.videos.arn,
      "${aws_dynamodb_table.videos.arn}/index/*"
    ]
  }

  # SQS - send messages to processing queue
  statement {
    sid    = "SQSSendMessage"
    effect = "Allow"
    actions = [
      "sqs:SendMessage",
      "sqs:GetQueueUrl"
    ]
    resources = [
      aws_sqs_queue.video_queue.arn
    ]
  }
}

resource "aws_iam_role_policy" "poller" {
  name   = "${local.lambda_poller_name}-policy"
  role   = aws_iam_role.poller.id
  policy = data.aws_iam_policy_document.poller.json
}

# =============================================================================
# PROCESSOR LAMBDA IAM
# =============================================================================

resource "aws_iam_role" "processor" {
  name               = "${local.lambda_processor_name}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = {
    Name = "Processor Lambda Role"
  }
}

data "aws_iam_policy_document" "processor" {
  # CloudWatch Logs - write logs
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = [
      "${aws_cloudwatch_log_group.processor.arn}:*"
    ]
  }

  # SSM Parameter Store - read configuration and API keys
  statement {
    sid    = "SSMReadConfig"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters"
    ]
    resources = [
      "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_prefix}/*"
    ]
  }

  # SQS - receive and delete messages
  statement {
    sid    = "SQSReceiveMessage"
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes"
    ]
    resources = [
      aws_sqs_queue.video_queue.arn
    ]
  }

  # DynamoDB - write summaries
  statement {
    sid    = "DynamoDBWrite"
    effect = "Allow"
    actions = [
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:GetItem"
    ]
    resources = [
      aws_dynamodb_table.videos.arn
    ]
  }
}

resource "aws_iam_role_policy" "processor" {
  name   = "${local.lambda_processor_name}-policy"
  role   = aws_iam_role.processor.id
  policy = data.aws_iam_policy_document.processor.json
}

# =============================================================================
# NEWSLETTER LAMBDA IAM
# =============================================================================

resource "aws_iam_role" "newsletter" {
  name               = "${local.lambda_newsletter_name}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = {
    Name = "Newsletter Lambda Role"
  }
}

data "aws_iam_policy_document" "newsletter" {
  # CloudWatch Logs - write logs
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = [
      "${aws_cloudwatch_log_group.newsletter.arn}:*"
    ]
  }

  # SSM Parameter Store - read configuration
  statement {
    sid    = "SSMReadConfig"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters"
    ]
    resources = [
      "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_prefix}/*"
    ]
  }

  # DynamoDB - read summaries
  statement {
    sid    = "DynamoDBRead"
    effect = "Allow"
    actions = [
      "dynamodb:Query",
      "dynamodb:GetItem"
    ]
    resources = [
      aws_dynamodb_table.videos.arn,
      "${aws_dynamodb_table.videos.arn}/index/*"
    ]
  }

  # SES - send emails
  statement {
    sid    = "SESSendEmail"
    effect = "Allow"
    actions = [
      "ses:SendEmail",
      "ses:SendRawEmail"
    ]
    resources = [
      "arn:aws:ses:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:identity/*"
    ]
  }
}

resource "aws_iam_role_policy" "newsletter" {
  name   = "${local.lambda_newsletter_name}-policy"
  role   = aws_iam_role.newsletter.id
  policy = data.aws_iam_policy_document.newsletter.json
}

# =============================================================================
# CLEANUP LAMBDA IAM
# =============================================================================

resource "aws_iam_role" "cleanup" {
  name               = "${local.lambda_cleanup_name}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = {
    Name = "Cleanup Lambda Role"
  }
}

data "aws_iam_policy_document" "cleanup" {
  # CloudWatch Logs - write logs
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = [
      "${aws_cloudwatch_log_group.cleanup.arn}:*"
    ]
  }

  # DynamoDB - scan and delete permanently failed records
  statement {
    sid    = "DynamoDBCleanup"
    effect = "Allow"
    actions = [
      "dynamodb:Scan",
      "dynamodb:DeleteItem",
      "dynamodb:GetItem"
    ]
    resources = [
      aws_dynamodb_table.videos.arn,
      "${aws_dynamodb_table.videos.arn}/index/*"
    ]
  }
}

resource "aws_iam_role_policy" "cleanup" {
  name   = "${local.lambda_cleanup_name}-policy"
  role   = aws_iam_role.cleanup.id
  policy = data.aws_iam_policy_document.cleanup.json
}
