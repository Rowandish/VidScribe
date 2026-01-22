#!/bin/bash
# =============================================================================
# VidScribe - Lambda Layer Builder
# =============================================================================
# Builds the Lambda layer containing Python dependencies.
# This script creates a ZIP file compatible with AWS Lambda.
#
# Usage:
#   ./scripts/build_layers.sh
#
# Output:
#   packages/dependencies-layer.zip
# =============================================================================

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Get the script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

# Configuration
LAYER_DIR="$PROJECT_ROOT/layer"
PACKAGES_DIR="$PROJECT_ROOT/packages"
REQUIREMENTS_FILE="$PROJECT_ROOT/src/processor/requirements.txt"
OUTPUT_ZIP="$PACKAGES_DIR/dependencies-layer.zip"
PYTHON_VERSION="python3.11"

print_info "Building Lambda layer..."
print_info "Project root: $PROJECT_ROOT"

# Create directories
mkdir -p "$LAYER_DIR/python"
mkdir -p "$PACKAGES_DIR"

# Clean previous builds
rm -rf "$LAYER_DIR/python/"*
rm -f "$OUTPUT_ZIP"

# Check if requirements file exists
if [ ! -f "$REQUIREMENTS_FILE" ]; then
    print_error "Requirements file not found: $REQUIREMENTS_FILE"
    exit 1
fi

print_info "Installing dependencies from: $REQUIREMENTS_FILE"

# Install dependencies
# Use --platform and --only-binary for Lambda compatibility
pip install \
    --target "$LAYER_DIR/python" \
    --platform manylinux2014_x86_64 \
    --implementation cp \
    --python-version 3.11 \
    --only-binary=:all: \
    --upgrade \
    -r "$REQUIREMENTS_FILE" 2>/dev/null || \
pip install \
    --target "$LAYER_DIR/python" \
    --upgrade \
    -r "$REQUIREMENTS_FILE"

# Remove unnecessary files to reduce layer size
print_info "Cleaning up unnecessary files..."
find "$LAYER_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$LAYER_DIR" -type d -name "*.dist-info" -exec rm -rf {} + 2>/dev/null || true
find "$LAYER_DIR" -type d -name "*.egg-info" -exec rm -rf {} + 2>/dev/null || true
find "$LAYER_DIR" -type f -name "*.pyc" -delete 2>/dev/null || true
find "$LAYER_DIR" -type f -name "*.pyo" -delete 2>/dev/null || true

# Create the ZIP file
print_info "Creating ZIP archive..."
cd "$LAYER_DIR"
zip -r "$OUTPUT_ZIP" python -x "*.pyc" -x "*__pycache__*"

# Calculate size
LAYER_SIZE=$(du -h "$OUTPUT_ZIP" | cut -f1)
print_success "Layer built successfully!"
print_info "Output: $OUTPUT_ZIP ($LAYER_SIZE)"

# Verify the layer structure
print_info "Layer contents:"
unzip -l "$OUTPUT_ZIP" | head -20

# Clean up
rm -rf "$LAYER_DIR"

echo ""
print_success "Lambda layer is ready for deployment."
