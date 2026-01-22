# =============================================================================
# VidScribe - SSM Parameter Store Configuration
# =============================================================================
# Stores application configuration that can be easily modified by users
# without redeploying infrastructure.
# =============================================================================

# -----------------------------------------------------------------------------
# YouTube Channels Configuration
# JSON list of YouTube channel IDs to monitor
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "youtube_channels" {
  name        = "${local.ssm_prefix}/youtube_channels"
  description = "JSON list of YouTube channel IDs to monitor. Example: [\"UCBcRF18a7Qf58cCRy5xuWwQ\"]"
  type        = "String"
  value       = var.youtube_channels
  tier        = "Standard"

  tags = {
    Name = "YouTube Channels Configuration"
  }
}

# -----------------------------------------------------------------------------
# Email Configuration
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "destination_email" {
  name        = "${local.ssm_prefix}/destination_email"
  description = "Email address to receive the weekly newsletter"
  type        = "String"
  value       = var.destination_email
  tier        = "Standard"

  tags = {
    Name = "Destination Email"
  }
}

resource "aws_ssm_parameter" "sender_email" {
  name        = "${local.ssm_prefix}/sender_email"
  description = "Email address to send newsletters from (must be verified in SES)"
  type        = "String"
  value       = var.sender_email
  tier        = "Standard"

  tags = {
    Name = "Sender Email"
  }
}

# -----------------------------------------------------------------------------
# LLM Configuration
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "llm_config" {
  name        = "${local.ssm_prefix}/llm_config"
  description = "LLM provider configuration. JSON with 'provider' (gemini/groq) and 'model' fields."
  type        = "String"
  value       = local.llm_config
  tier        = "Standard"

  tags = {
    Name = "LLM Configuration"
  }
}

# -----------------------------------------------------------------------------
# API Keys (Secure Strings)
# These are stored as SecureString for encryption at rest
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "youtube_api_key" {
  name        = "${local.ssm_prefix}/youtube_api_key"
  description = "YouTube Data API v3 key for accessing channel data"
  type        = "SecureString"
  value       = var.youtube_api_key != "" ? var.youtube_api_key : "PLACEHOLDER_REPLACE_ME"
  tier        = "Standard"

  tags = {
    Name = "YouTube API Key"
  }

  lifecycle {
    # Ignore changes to value - users will update this via console/CLI
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "llm_api_key" {
  name        = "${local.ssm_prefix}/llm_api_key"
  description = "API key for the LLM provider (Gemini or Groq)"
  type        = "SecureString"
  value       = var.llm_api_key != "" ? var.llm_api_key : "PLACEHOLDER_REPLACE_ME"
  tier        = "Standard"

  tags = {
    Name = "LLM API Key"
  }

  lifecycle {
    # Ignore changes to value - users will update this via console/CLI
    ignore_changes = [value]
  }
}
