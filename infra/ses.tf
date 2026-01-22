# =============================================================================
# VidScribe - SES Configuration
# =============================================================================
# Email identity verification for sending newsletters.
# Note: SES starts in sandbox mode - you must verify both sender and recipient
# or request production access.
# =============================================================================

# -----------------------------------------------------------------------------
# Email Identity for Sender
# This email address must be verified before it can send emails
# -----------------------------------------------------------------------------

resource "aws_ses_email_identity" "sender" {
  count = var.sender_email != "" ? 1 : 0
  email = var.sender_email
}

# -----------------------------------------------------------------------------
# Email Identity for Recipient (required in sandbox mode)
# In production mode, you don't need to verify recipients
# -----------------------------------------------------------------------------

resource "aws_ses_email_identity" "recipient" {
  count = var.destination_email != "" && var.destination_email != var.sender_email ? 1 : 0
  email = var.destination_email
}

# -----------------------------------------------------------------------------
# SES Configuration Set (optional, for tracking)
# Provides tracking for bounces, complaints, and delivery
# -----------------------------------------------------------------------------

resource "aws_ses_configuration_set" "newsletter" {
  name = "${local.name_prefix}-newsletter"

  reputation_metrics_enabled = false # Set to true if you want delivery metrics
  sending_enabled            = true

  # Note: For production, consider adding:
  # - Event destinations for tracking
  # - Suppression list options
}
