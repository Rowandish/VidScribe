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
  value       = jsonencode(var.youtube_channels)
  tier        = "Standard"

  tags = {
    Name = "YouTube Channels Configuration"
  }

  lifecycle {
    # Ignore changes to value - users will update this via console/CLI
    ignore_changes = [value]
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

  lifecycle {
    # Ignore changes to value - users will update this via console/CLI
    ignore_changes = [value]
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

  lifecycle {
    # Ignore changes to value - users will update this via console/CLI
    ignore_changes = [value]
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

  lifecycle {
    # Ignore changes to value - users will update this via console/CLI
    ignore_changes = [value]
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

# -----------------------------------------------------------------------------
# Webshare Proxy Credentials (Optional)
# Used by Processor Lambda to avoid YouTube IP blocking
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "webshare_username" {
  name        = "${local.ssm_prefix}/webshare_username"
  description = "Webshare proxy username for YouTube transcript downloads"
  type        = "String"
  value       = var.webshare_username != "" ? var.webshare_username : "PLACEHOLDER"
  tier        = "Standard"

  tags = {
    Name = "Webshare Username"
  }

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "webshare_password" {
  name        = "${local.ssm_prefix}/webshare_password"
  description = "Webshare proxy password for YouTube transcript downloads"
  type        = "SecureString"
  value       = var.webshare_password != "" ? var.webshare_password : "PLACEHOLDER"
  tier        = "Standard"

  tags = {
    Name = "Webshare Password"
  }

  lifecycle {
    ignore_changes = [value]
  }
}

# -----------------------------------------------------------------------------
# Gmail SMTP Configuration (Optional - Alternative to SES)
# Used by Newsletter Lambda when use_gmail_smtp is true
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "use_gmail_smtp" {
  name        = "${local.ssm_prefix}/use_gmail_smtp"
  description = "Set to 'true' to use Gmail SMTP instead of AWS SES"
  type        = "String"
  value       = var.use_gmail_smtp ? "true" : "false"
  tier        = "Standard"

  tags = {
    Name = "Use Gmail SMTP Flag"
  }

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "gmail_sender" {
  name        = "${local.ssm_prefix}/gmail_sender"
  description = "Gmail address to send from (e.g. user@gmail.com)"
  type        = "String"
  value       = var.gmail_sender != "" ? var.gmail_sender : "PLACEHOLDER"
  tier        = "Standard"

  tags = {
    Name = "Gmail Sender"
  }

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "gmail_app_password" {
  name        = "${local.ssm_prefix}/gmail_app_password"
  description = "Gmail App Password for SMTP authentication"
  type        = "SecureString"
  value       = var.gmail_app_password != "" ? var.gmail_app_password : "PLACEHOLDER"
  tier        = "Standard"

  tags = {
    Name = "Gmail App Password"
  }

  lifecycle {
    ignore_changes = [value]
  }
}

# -----------------------------------------------------------------------------
# Generic Proxy Configuration (Optional - Alternative to Webshare)
# Allows using any HTTP/HTTPS/SOCKS proxy provider
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "proxy_type" {
  name        = "${local.ssm_prefix}/proxy_type"
  description = "Proxy type: 'webshare', 'generic', or 'none'"
  type        = "String"
  value       = var.proxy_type
  tier        = "Standard"

  tags = {
    Name = "Proxy Type"
  }

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "generic_proxy_http_url" {
  name        = "${local.ssm_prefix}/generic_proxy_http_url"
  description = "HTTP proxy URL (format: http://user:pass@host:port)"
  type        = "SecureString"
  value       = var.generic_proxy_http_url != "" ? var.generic_proxy_http_url : "PLACEHOLDER"
  tier        = "Standard"

  tags = {
    Name = "Generic Proxy HTTP URL"
  }

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "generic_proxy_https_url" {
  name        = "${local.ssm_prefix}/generic_proxy_https_url"
  description = "HTTPS proxy URL (format: https://user:pass@host:port)"
  type        = "SecureString"
  value       = var.generic_proxy_https_url != "" ? var.generic_proxy_https_url : "PLACEHOLDER"
  tier        = "Standard"

  tags = {
    Name = "Generic Proxy HTTPS URL"
  }

  lifecycle {
    ignore_changes = [value]
  }
}
