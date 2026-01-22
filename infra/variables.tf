# =============================================================================
# VidScribe - Input Variables
# =============================================================================

# -----------------------------------------------------------------------------
# General Configuration
# -----------------------------------------------------------------------------

variable "project_name" {
  description = "Name of the project, used for resource naming"
  type        = string
  default     = "vidscribe"
}

variable "environment" {
  description = "Environment name (e.g., dev, staging, prod)"
  type        = string
  default     = "prod"
}

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-west-1"
}

variable "use_windows_scripts" {
  description = "Set to true to use PowerShell scripts instead of Bash (for Windows users)"
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Lambda Configuration
# -----------------------------------------------------------------------------

variable "lambda_runtime" {
  description = "Python runtime version for Lambda functions"
  type        = string
  default     = "python3.11"
}

variable "poller_timeout" {
  description = "Timeout in seconds for the Poller Lambda"
  type        = number
  default     = 60
}

variable "poller_memory" {
  description = "Memory in MB for the Poller Lambda"
  type        = number
  default     = 256
}

variable "processor_timeout" {
  description = "Timeout in seconds for the Processor Lambda"
  type        = number
  default     = 120
}

variable "processor_memory" {
  description = "Memory in MB for the Processor Lambda"
  type        = number
  default     = 512
}

variable "newsletter_timeout" {
  description = "Timeout in seconds for the Newsletter Lambda"
  type        = number
  default     = 60
}

variable "newsletter_memory" {
  description = "Memory in MB for the Newsletter Lambda"
  type        = number
  default     = 256
}

# -----------------------------------------------------------------------------
# DynamoDB Configuration
# -----------------------------------------------------------------------------

variable "dynamodb_ttl_days" {
  description = "Number of days before records are automatically deleted"
  type        = number
  default     = 30
}

# -----------------------------------------------------------------------------
# SQS Configuration
# -----------------------------------------------------------------------------

variable "sqs_max_receive_count" {
  description = "Number of times a message can be received before moving to DLQ"
  type        = number
  default     = 3
}

variable "sqs_message_retention_seconds" {
  description = "How long messages are retained in the queue (in seconds)"
  type        = number
  default     = 345600 # 4 days
}

# -----------------------------------------------------------------------------
# EventBridge Configuration
# -----------------------------------------------------------------------------

variable "poller_schedule" {
  description = "Cron expression for the Poller Lambda (every 12 hours)"
  type        = string
  default     = "rate(12 hours)"
}

variable "newsletter_schedule" {
  description = "Cron expression for the Newsletter Lambda (Saturday 09:00 UTC)"
  type        = string
  default     = "cron(0 9 ? * SAT *)"
}

# -----------------------------------------------------------------------------
# CloudWatch Configuration
# -----------------------------------------------------------------------------

variable "log_retention_days" {
  description = "Number of days to retain CloudWatch logs"
  type        = number
  default     = 7
}

# -----------------------------------------------------------------------------
# SSM Parameter Store - Default Values
# These are the default values that will be stored in SSM Parameter Store.
# Users can modify these after deployment via the AWS Console or CLI.
# -----------------------------------------------------------------------------

variable "youtube_channels" {
  description = "JSON list of YouTube channel IDs to monitor"
  type        = string
  default     = "[\"UCBcRF18a7Qf58cCRy5xuWwQ\"]" # Example: MKBHD channel
}

variable "destination_email" {
  description = "Email address to receive the newsletter"
  type        = string
  default     = ""
}

variable "sender_email" {
  description = "Email address to send the newsletter from (must be verified in SES)"
  type        = string
  default     = ""
}

variable "admin_email" {
  description = "Email address for error notifications"
  type        = string
  default     = ""
}

variable "llm_provider" {
  description = "LLM provider to use: 'gemini' or 'groq'"
  type        = string
  default     = "gemini"

  validation {
    condition     = contains(["gemini", "groq"], var.llm_provider)
    error_message = "LLM provider must be either 'gemini' or 'groq'."
  }
}

variable "llm_model" {
  description = "Model name for the LLM provider"
  type        = string
  default     = "gemini-1.5-flash"
}

# -----------------------------------------------------------------------------
# Sensitive Variables (should be passed via environment or secrets)
# -----------------------------------------------------------------------------

variable "youtube_api_key" {
  description = "YouTube Data API v3 key (stored in SSM as SecureString)"
  type        = string
  default     = ""
}

variable "llm_api_key" {
  description = "API key for the LLM provider - Gemini or Groq (stored in SSM as SecureString)"
  type        = string
  default     = ""
}
