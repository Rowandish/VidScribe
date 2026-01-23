#!/bin/bash
# =============================================================================
# VidScribe - Lambda Layer Builder
# =============================================================================
# Builds the Lambda layer containing Python dependencies in a *deterministic*
# way so Terraform does not recreate the layer on every run.
#
# Usage:
#   ./scripts/build_layers.sh
#
# Output:
#   packages/dependencies-layer.zip
# =============================================================================

set -euo pipefail
umask 022

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

LAYER_DIR="$PROJECT_ROOT/layer"
PACKAGES_DIR="$PROJECT_ROOT/packages"
REQUIREMENTS_FILE="$PROJECT_ROOT/src/processor/requirements.txt"
OUTPUT_ZIP="$PACKAGES_DIR/dependencies-layer.zip"

# Fixed timestamp used to normalize all files inside the ZIP.
# Any constant is fine; it just needs to be stable.
FIXED_TS="202001010000.00"

print_info "Building Lambda layer (deterministic zip)..."
print_info "Project root: $PROJECT_ROOT"

mkdir -p "$LAYER_DIR/python" "$PACKAGES_DIR"
rm -rf "$LAYER_DIR/python/"* || true
rm -f "$OUTPUT_ZIP" || true

if [ ! -f "$REQUIREMENTS_FILE" ]; then
  print_error "Requirements file not found: $REQUIREMENTS_FILE"
  exit 1
fi

if ! command -v pip >/dev/null 2>&1; then
  print_error "pip not found. Install Python/pip before running this script."
  exit 1
fi

print_info "Installing dependencies from: $REQUIREMENTS_FILE"

# Prefer Lambda-compatible wheels when possible (Linux build environments).
# Fallback to a standard install when --platform is not supported or wheels are missing.
set +e
pip install \
  --target "$LAYER_DIR/python" \
  --platform manylinux2014_x86_64 \
  --implementation cp \
  --python-version 3.11 \
  --only-binary=:all: \
  --upgrade \
  -r "$REQUIREMENTS_FILE" 2>/dev/null
PIP_RC=$?
set -e

if [ "$PIP_RC" -ne 0 ]; then
  print_warn "Platform-specific install failed; falling back to standard pip install."
  pip install \
    --target "$LAYER_DIR/python" \
    --upgrade \
    -r "$REQUIREMENTS_FILE"
fi

print_info "Cleaning up unnecessary files..."
find "$LAYER_DIR" -type d -name "__pycache__" -prune -exec rm -rf {} + 2>/dev/null || true
find "$LAYER_DIR" -type f -name "*.pyc" -delete 2>/dev/null || true
find "$LAYER_DIR" -type f -name "*.pyo" -delete 2>/dev/null || true

# Remove common test folders to reduce size (generally safe)
find "$LAYER_DIR/python" -type d \( -iname "tests" -o -iname "test" \) -prune -exec rm -rf {} + 2>/dev/null || true

# Normalize permissions (avoid umask differences between environments)
chmod -R u=rwX,go=rX "$LAYER_DIR/python" 2>/dev/null || true

# Normalize timestamps so the resulting ZIP is byte-for-byte reproducible
print_info "Normalizing timestamps to $FIXED_TS..."
find "$LAYER_DIR/python" -exec touch -h -t "$FIXED_TS" {} + 2>/dev/null || \
find "$LAYER_DIR/python" -exec touch -t "$FIXED_TS" {} + 2>/dev/null || true

# Create a deterministic ZIP:
# - zip -X: exclude extra file attributes
# - stable ordering: sort file list with LC_ALL=C
print_info "Creating ZIP archive..."
cd "$LAYER_DIR"
FILELIST="$(mktemp)"

# Include only files; directories will be created implicitly by zip.
LC_ALL=C find python -type f -print | sort > "$FILELIST"
zip -X -q -@ "$OUTPUT_ZIP" < "$FILELIST"
rm -f "$FILELIST"

# Size + checksum (useful for debugging)
LAYER_SIZE=$(du -h "$OUTPUT_ZIP" | cut -f1)
if command -v sha256sum >/dev/null 2>&1; then
  LAYER_SHA=$(sha256sum "$OUTPUT_ZIP" | awk '{print $1}')
  print_info "SHA256: $LAYER_SHA"
fi

print_success "Layer built successfully!"
print_info "Output: $OUTPUT_ZIP ($LAYER_SIZE)"

print_info "Layer contents (first 20 entries):"
unzip -l "$OUTPUT_ZIP" | head -20

# Clean up build dir (the ZIP is the artifact)
rm -rf "$LAYER_DIR"

echo ""
print_success "Lambda layer is ready for deployment."
