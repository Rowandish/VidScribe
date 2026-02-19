#!/bin/bash
# =============================================================================
# VidScribe - Setup Script
# =============================================================================
# This script automates the initial setup of VidScribe infrastructure.
# It creates the S3 bucket and DynamoDB table for Terraform state management.
#
# Prerequisites:
#   - AWS CLI installed and configured
#   - Terraform installed (>= 1.0.0)
#   - Bash shell
#
# Usage:
#   ./scripts/setup.sh <bucket-name> [region]
#
# Example:
#   ./scripts/setup.sh my-vidscribe-tf-state eu-west-1
# =============================================================================

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    print_info "Checking prerequisites..."
    
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is not installed. Please install it first."
        exit 1
    fi
    
    if ! command -v terraform &> /dev/null; then
        print_error "Terraform is not installed. Please install it first."
        exit 1
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "AWS credentials not configured. Run 'aws configure' first."
        exit 1
    fi
    
    print_success "All prerequisites met."
}

# Show usage
show_usage() {
    echo "Usage: $0 <bucket-name> [region]"
    echo ""
    echo "Arguments:"
    echo "  bucket-name    Globally unique name for the Terraform state bucket"
    echo "  region         AWS region (default: eu-west-1)"
    echo ""
    echo "Example:"
    echo "  $0 my-vidscribe-tf-state eu-west-1"
}

# Main script
main() {
    echo ""
    echo "=========================================="
    echo "   VidScribe Setup Script"
    echo "=========================================="
    echo ""
    
    # Check arguments
    if [ $# -lt 1 ]; then
        print_error "Missing required argument: bucket-name"
        show_usage
        exit 1
    fi
    
    BUCKET_NAME=$1
    AWS_REGION=${2:-eu-west-1}
    DYNAMODB_TABLE="vidscribe-terraform-lock"
    
    print_info "Configuration:"
    echo "  Bucket Name:    $BUCKET_NAME"
    echo "  AWS Region:     $AWS_REGION"
    echo "  DynamoDB Table: $DYNAMODB_TABLE"
    echo ""
    
    # Check prerequisites
    check_prerequisites
    
    # Get the script directory
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"
    BOOTSTRAP_DIR="$PROJECT_ROOT/infra/bootstrap"
    
    print_info "Project root: $PROJECT_ROOT"
    
    # Step 1: Initialize and apply bootstrap Terraform
    print_info "Step 1: Creating Terraform state infrastructure..."
    
    cd "$BOOTSTRAP_DIR"
    
    # Initialize Terraform
    print_info "Initializing Terraform..."
    terraform init -input=false
    
    # Plan
    print_info "Planning infrastructure changes..."
    terraform plan \
        -var="bucket_name=$BUCKET_NAME" \
        -var="aws_region=$AWS_REGION" \
        -var="dynamodb_table_name=$DYNAMODB_TABLE" \
        -out=tfplan
    
    # Apply
    print_info "Applying infrastructure changes..."
    terraform apply -input=false tfplan
    
    rm -f tfplan
    
    print_success "Bootstrap infrastructure created!"
    
    # Step 2: Build Lambda layers
    print_info "Step 2: Building Lambda layers..."
    cd "$PROJECT_ROOT"
    bash scripts/build_layers.sh
    
    print_success "Lambda layers built!"
    
    # Step 3: Show next steps
    echo ""
    echo "=========================================="
    echo "   Setup Complete!"
    echo "=========================================="
    echo ""
    print_success "Terraform state infrastructure is ready."
    echo ""
    echo "Next steps:"
    echo ""
    echo "1. Configure your API keys in the Terraform variables or environment:"
    echo "   export TF_VAR_youtube_api_key='your-youtube-api-key'"
    echo "   export TF_VAR_llm_api_key='your-gemini-or-groq-api-key'"
    echo ""
    echo "2. Configure your email settings in infra/terraform.tfvars:"
    echo "   cp infra/terraform.tfvars.example infra/terraform.tfvars"
    echo "   # Edit terraform.tfvars with your email addresses"
    echo ""
    echo "3. Initialize and apply the main Terraform configuration:"
    echo "   cd infra"
    echo "   terraform init \\"
    echo "     -backend-config=\"bucket=$BUCKET_NAME\" \\"
    echo "     -backend-config=\"use_lockfile=true\" \\"
    echo "     -backend-config=\"region=$AWS_REGION\""
    echo ""
    echo "   terraform plan"
    echo "   terraform apply"
    echo ""
    echo "4. Verify your SES email addresses by clicking the confirmation links."
    echo ""
    echo "5. (Optional) Manually trigger the Poller to test:"
    echo "   aws lambda invoke --function-name vidscribe-prod-poller output.json"
    echo ""
}

# Run main function
main "$@"
