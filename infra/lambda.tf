# =============================================================================
# VidScribe - Lambda Functions Configuration
# =============================================================================
# Defines all three Lambda functions with their configurations.
# =============================================================================

# -----------------------------------------------------------------------------
# Lambda Layer for Dependencies
# Contains youtube-transcript-api and other shared dependencies
# NOTE: Run scripts/build_layers.ps1 (Windows) or scripts/build_layers.sh (Linux)
#       BEFORE running terraform apply
# -----------------------------------------------------------------------------

resource "aws_lambda_layer_version" "dependencies" {
  filename            = "${path.module}/../packages/dependencies-layer.zip"
  layer_name          = "${local.name_prefix}-dependencies"
  compatible_runtimes = [var.lambda_runtime]
  description         = "Shared dependencies including youtube-transcript-api"

  source_code_hash = filebase64sha256("${path.module}/../packages/dependencies-layer.zip")

  lifecycle {
    # Create the new layer version first, then update functions, then remove the old version.
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Archive Lambda Source Code
# -----------------------------------------------------------------------------

data "archive_file" "poller" {
  type        = "zip"
  source_dir  = "${path.root}/../src/poller"
  output_path = "${path.root}/../packages/poller.zip"
  excludes    = ["__pycache__", "*.pyc", "requirements.txt"]
}

data "archive_file" "processor" {
  type        = "zip"
  source_dir  = "${path.root}/../src/processor"
  output_path = "${path.root}/../packages/processor.zip"
  excludes    = ["__pycache__", "*.pyc", "requirements.txt"]
}

data "archive_file" "newsletter" {
  type        = "zip"
  source_dir  = "${path.root}/../src/newsletter"
  output_path = "${path.root}/../packages/newsletter.zip"
  excludes    = ["__pycache__", "*.pyc", "requirements.txt"]
}

# -----------------------------------------------------------------------------
# Poller Lambda Function
# Triggered by EventBridge every 12 hours to check for new videos
# -----------------------------------------------------------------------------

resource "aws_lambda_function" "poller" {
  function_name = local.lambda_poller_name
  description   = "Polls YouTube channels for new videos and sends them to SQS"

  filename         = data.archive_file.poller.output_path
  source_code_hash = data.archive_file.poller.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = var.lambda_runtime

  role        = aws_iam_role.poller.arn
  timeout     = var.poller_timeout
  memory_size = var.poller_memory

  environment {
    variables = {
      DYNAMODB_TABLE_NAME     = aws_dynamodb_table.videos.name
      SQS_QUEUE_URL           = aws_sqs_queue.video_queue.url
      SSM_YOUTUBE_CHANNELS    = aws_ssm_parameter.youtube_channels.name
      SSM_YOUTUBE_API_KEY     = aws_ssm_parameter.youtube_api_key.name
      TTL_DAYS                = var.dynamodb_ttl_days
      POWERTOOLS_SERVICE_NAME = "vidscribe-poller"
      LOG_LEVEL               = "INFO"
    }
  }

  # Ensure log group exists before Lambda
  depends_on = [aws_cloudwatch_log_group.poller]

  tags = {
    Name     = "Poller Lambda"
    Function = "poller"
  }
}

# -----------------------------------------------------------------------------
# Processor Lambda Function
# Triggered by SQS to process videos (download transcript, summarize with LLM)
# -----------------------------------------------------------------------------

resource "aws_lambda_function" "processor" {
  function_name = local.lambda_processor_name
  description   = "Downloads transcripts and summarizes videos using LLM"

  filename         = data.archive_file.processor.output_path
  source_code_hash = data.archive_file.processor.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = var.lambda_runtime

  role        = aws_iam_role.processor.arn
  timeout     = var.processor_timeout
  memory_size = var.processor_memory

  # Attach the dependencies layer (versioned ARN)
  layers = [aws_lambda_layer_version.dependencies.arn]

  environment {
    variables = {
      DYNAMODB_TABLE_NAME     = aws_dynamodb_table.videos.name
      SSM_LLM_CONFIG          = aws_ssm_parameter.llm_config.name
      SSM_LLM_API_KEY         = aws_ssm_parameter.llm_api_key.name
      TTL_DAYS                = var.dynamodb_ttl_days
      POWERTOOLS_SERVICE_NAME = "vidscribe-processor"
      LOG_LEVEL               = "INFO"
      # Proxy configuration - passed directly to avoid SSM reads
      PROXY_TYPE              = var.proxy_type
      WEBSHARE_USERNAME       = var.webshare_username
      WEBSHARE_PASSWORD       = var.webshare_password
      GENERIC_PROXY_HTTP_URL  = var.generic_proxy_http_url
      GENERIC_PROXY_HTTPS_URL = var.generic_proxy_https_url
    }
  }

  depends_on = [aws_cloudwatch_log_group.processor]

  tags = {
    Name     = "Processor Lambda"
    Function = "processor"
  }
}

# SQS Event Source Mapping for Processor Lambda
resource "aws_lambda_event_source_mapping" "processor_sqs" {
  event_source_arn = aws_sqs_queue.video_queue.arn
  function_name    = aws_lambda_function.processor.arn
  batch_size       = 1 # Process one video at a time

  # Enable partial batch failure reporting
  function_response_types = ["ReportBatchItemFailures"]
}

# -----------------------------------------------------------------------------
# Newsletter Lambda Function
# Triggered by EventBridge every Saturday to send weekly digest
# -----------------------------------------------------------------------------

resource "aws_lambda_function" "newsletter" {
  function_name = local.lambda_newsletter_name
  description   = "Compiles and sends weekly newsletter via SES"

  filename         = data.archive_file.newsletter.output_path
  source_code_hash = data.archive_file.newsletter.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = var.lambda_runtime

  role        = aws_iam_role.newsletter.arn
  timeout     = var.newsletter_timeout
  memory_size = var.newsletter_memory

  # Attach the dependencies layer (versioned ARN)
  layers = [aws_lambda_layer_version.dependencies.arn]

  environment {
    variables = {
      DYNAMODB_TABLE_NAME     = aws_dynamodb_table.videos.name
      SSM_DESTINATION_EMAIL   = aws_ssm_parameter.destination_email.name
      SSM_SENDER_EMAIL        = aws_ssm_parameter.sender_email.name
      AWS_SES_REGION          = var.aws_region
      POWERTOOLS_SERVICE_NAME = "vidscribe-newsletter"
      LOG_LEVEL               = "INFO"
      # Gmail SMTP configuration - passed directly to avoid SSM reads
      USE_GMAIL_SMTP          = var.use_gmail_smtp ? "true" : "false"
      GMAIL_SENDER            = var.gmail_sender
      GMAIL_APP_PASSWORD      = var.gmail_app_password
    }
  }

  depends_on = [aws_cloudwatch_log_group.newsletter]

  tags = {
    Name     = "Newsletter Lambda"
    Function = "newsletter"
  }
}

# -----------------------------------------------------------------------------
# Cleanup Lambda Function
# Triggered by EventBridge monthly to clean up permanently failed records
# -----------------------------------------------------------------------------

data "archive_file" "cleanup" {
  type        = "zip"
  source_dir  = "${path.root}/../src/cleanup"
  output_path = "${path.root}/../packages/cleanup.zip"
  excludes    = ["__pycache__", "*.pyc"]
}

resource "aws_lambda_function" "cleanup" {
  function_name = local.lambda_cleanup_name
  description   = "Monthly cleanup of permanently failed records from DynamoDB"

  filename         = data.archive_file.cleanup.output_path
  source_code_hash = data.archive_file.cleanup.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = var.lambda_runtime

  role        = aws_iam_role.cleanup.arn
  timeout     = 120
  memory_size = 256

  environment {
    variables = {
      DYNAMODB_TABLE_NAME     = aws_dynamodb_table.videos.name
      CLEANUP_AGE_DAYS        = "30"
      POWERTOOLS_SERVICE_NAME = "vidscribe-cleanup"
      LOG_LEVEL               = "INFO"
    }
  }

  depends_on = [aws_cloudwatch_log_group.cleanup]

  tags = {
    Name     = "Cleanup Lambda"
    Function = "cleanup"
  }
}
