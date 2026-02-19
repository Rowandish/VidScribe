# =============================================================================
# VidScribe - Setup Script (PowerShell)
# =============================================================================
# This script automates the initial setup of VidScribe infrastructure.
# It creates the S3 bucket and DynamoDB table for Terraform state management.
#
# Prerequisites:
#   - AWS CLI installed and configured
#   - Terraform installed (>= 1.0.0)
#   - PowerShell 5.1+
#
# Usage:
#   .\scripts\setup.ps1 -BucketName "your-unique-bucket-name" [-Region "eu-west-1"]
#
# Example:
#   .\scripts\setup.ps1 -BucketName "my-vidscribe-tf-state" -Region "eu-west-1"
# =============================================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$BucketName,
    
    [Parameter(Mandatory=$false)]
    [string]$Region = "eu-west-1"
)

$ErrorActionPreference = "Stop"

# Colors
function Write-Info { param($Message) Write-Host "[INFO] $Message" -ForegroundColor Blue }
function Write-Success { param($Message) Write-Host "[SUCCESS] $Message" -ForegroundColor Green }
function Write-Warning { param($Message) Write-Host "[WARNING] $Message" -ForegroundColor Yellow }
function Write-Error { param($Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }

# Check prerequisites
function Test-Prerequisites {
    Write-Info "Checking prerequisites..."
    
    # Check AWS CLI
    if (-not (Get-Command "aws" -ErrorAction SilentlyContinue)) {
        Write-Error "AWS CLI is not installed. Please install it first."
        exit 1
    }
    
    # Check Terraform
    if (-not (Get-Command "terraform" -ErrorAction SilentlyContinue)) {
        Write-Error "Terraform is not installed. Please install it first."
        exit 1
    }
    
    # Check AWS credentials
    try {
        aws sts get-caller-identity | Out-Null
    } catch {
        Write-Error "AWS credentials not configured. Run 'aws configure' first."
        exit 1
    }
    
    Write-Success "All prerequisites met."
}

# Main script
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "   VidScribe Setup Script (PowerShell)" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

$DynamoDBTable = "vidscribe-terraform-lock"

Write-Info "Configuration:"
Write-Host "  Bucket Name:    $BucketName"
Write-Host "  AWS Region:     $Region"
Write-Host "  DynamoDB Table: $DynamoDBTable"
Write-Host ""

# Check prerequisites
Test-Prerequisites

# Get script directory
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$BootstrapDir = Join-Path $ProjectRoot "infra\bootstrap"

Write-Info "Project root: $ProjectRoot"

# Step 1: Initialize and apply bootstrap Terraform
Write-Info "Step 1: Creating Terraform state infrastructure..."

Push-Location $BootstrapDir
try {
    # Initialize Terraform
    Write-Info "Initializing Terraform..."
    terraform init -input=false
    
    # Plan
    Write-Info "Planning infrastructure changes..."
    terraform plan `
        -var="bucket_name=$BucketName" `
        -var="aws_region=$Region" `
        -var="dynamodb_table_name=$DynamoDBTable" `
        -out=tfplan
    
    # Apply
    Write-Info "Applying infrastructure changes..."
    terraform apply -input=false tfplan
    
    Remove-Item -Force tfplan -ErrorAction SilentlyContinue
} finally {
    Pop-Location
}

Write-Success "Bootstrap infrastructure created!"

# Step 2: Build Lambda layers
Write-Info "Step 2: Building Lambda layers..."
Push-Location $ProjectRoot
try {
    & (Join-Path $ScriptDir "build_layers.ps1")
} finally {
    Pop-Location
}

Write-Success "Lambda layers built!"

# Step 3: Show next steps
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "   Setup Complete!" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
Write-Success "Terraform state infrastructure is ready."
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host ""
Write-Host "1. Configure your API keys in environment variables:"
Write-Host "   `$env:TF_VAR_youtube_api_key='your-youtube-api-key'"
Write-Host "   `$env:TF_VAR_llm_api_key='your-gemini-or-groq-api-key'"
Write-Host ""
Write-Host "2. Configure your email settings in infra\terraform.tfvars:"
Write-Host "   Copy-Item infra\terraform.tfvars.example infra\terraform.tfvars"
Write-Host "   # Edit terraform.tfvars with your email addresses"
Write-Host ""
Write-Host "3. Initialize and apply the main Terraform configuration:"
Write-Host "   cd infra"
Write-Host "   terraform init ```"
Write-Host "     -backend-config=`"bucket=$BucketName`" ```"
Write-Host "     -backend-config=`"use_lockfile=true`" ```"
Write-Host "     -backend-config=`"region=$Region`""
Write-Host ""
Write-Host "   terraform plan"
Write-Host "   terraform apply"
Write-Host ""
Write-Host "4. Verify your SES email addresses by clicking the confirmation links."
Write-Host ""
Write-Host "5. (Optional) Manually trigger the Poller to test:"
Write-Host "   aws lambda invoke --function-name vidscribe-prod-poller output.json"
Write-Host ""
