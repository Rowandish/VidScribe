# =============================================================================
# VidScribe - Terraform Backend Configuration
# =============================================================================
# This configures Terraform to store state in S3 with S3 lockfile locking.
# The bucket must be created first using infra/bootstrap/main.tf
#
# IMPORTANT: Before running terraform init, you must either:
#   1. Set environment variables:
#      export TF_VAR_state_bucket="your-bucket-name"
#      export TF_VAR_state_lock_table="vidscribe-terraform-lock"  # Legacy bootstrap output
#   
#   2. Or use -backend-config flags:
#      terraform init \
#        -backend-config="bucket=your-bucket-name" \
#        -backend-config="use_lockfile=true" \
#        -backend-config="region=eu-west-1"
# =============================================================================

terraform {
  backend "s3" {
    # These values are configured via -backend-config or environment variables
    # bucket         = "your-terraform-state-bucket"  # Set via -backend-config
    # use_lockfile   = true                           # Set via -backend-config
    # region         = "eu-west-1"                    # Set via -backend-config

    key          = "vidscribe/terraform.tfstate"
    use_lockfile = true
    encrypt      = true
  }
}
