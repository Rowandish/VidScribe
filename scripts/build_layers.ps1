# =============================================================================
# VidScribe - Lambda Layer Builder (PowerShell)
# =============================================================================
# Builds the Lambda layer containing Python dependencies.
# This script creates a ZIP file compatible with AWS Lambda.
#
# Usage:
#   .\scripts\build_layers.ps1
#
# Output:
#   packages\dependencies-layer.zip
# =============================================================================

$ErrorActionPreference = "Stop"

# Colors
function Write-Info { param($Message) Write-Host "[INFO] $Message" -ForegroundColor Blue }
function Write-Success { param($Message) Write-Host "[SUCCESS] $Message" -ForegroundColor Green }
function Write-Error { param($Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }

# Get script directory
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

# Configuration
$LayerDir = Join-Path $ProjectRoot "layer"
$PackagesDir = Join-Path $ProjectRoot "packages"
$RequirementsFile = Join-Path $ProjectRoot "src\processor\requirements.txt"
$OutputZip = Join-Path $PackagesDir "dependencies-layer.zip"

Write-Info "Building Lambda layer..."
Write-Info "Project root: $ProjectRoot"

# Create directories
New-Item -ItemType Directory -Force -Path (Join-Path $LayerDir "python") | Out-Null
New-Item -ItemType Directory -Force -Path $PackagesDir | Out-Null

# Clean previous builds
if (Test-Path (Join-Path $LayerDir "python\*")) {
    Remove-Item -Recurse -Force (Join-Path $LayerDir "python\*")
}
if (Test-Path $OutputZip) {
    Remove-Item -Force $OutputZip
}

# Check requirements file
if (-not (Test-Path $RequirementsFile)) {
    Write-Error "Requirements file not found: $RequirementsFile"
    exit 1
}

Write-Info "Installing dependencies from: $RequirementsFile"

# Install dependencies
$PythonDir = Join-Path $LayerDir "python"
try {
    # Try with Lambda-compatible platform first
    pip install --target $PythonDir --platform manylinux2014_x86_64 --implementation cp --python-version 3.11 --only-binary=:all: --upgrade -r $RequirementsFile 2>$null
} catch {
    # Fallback to regular install
    pip install --target $PythonDir --upgrade -r $RequirementsFile
}

# Clean up unnecessary files
Write-Info "Cleaning up unnecessary files..."
Get-ChildItem -Path $LayerDir -Recurse -Directory -Filter "__pycache__" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $LayerDir -Recurse -Directory -Filter "*.dist-info" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $LayerDir -Recurse -Directory -Filter "*.egg-info" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $LayerDir -Recurse -File -Filter "*.pyc" | Remove-Item -Force -ErrorAction SilentlyContinue

# Create ZIP file
Write-Info "Creating ZIP archive..."
Push-Location $LayerDir
try {
    Compress-Archive -Path "python" -DestinationPath $OutputZip -Force
} finally {
    Pop-Location
}

# Get file size
$LayerSize = (Get-Item $OutputZip).Length / 1KB
Write-Success "Layer built successfully!"
Write-Info "Output: $OutputZip ($([math]::Round($LayerSize, 2)) KB)"

# Clean up layer directory
Remove-Item -Recurse -Force $LayerDir -ErrorAction SilentlyContinue

Write-Host ""
Write-Success "Lambda layer is ready for deployment."
