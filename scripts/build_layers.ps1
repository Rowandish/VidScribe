# =============================================================================
# VidScribe - Lambda Layer Builder (PowerShell, deterministic)
# =============================================================================
# Usage:
#   .\scripts\build_layers.ps1
#
# Output:
#   packages\dependencies-layer.zip
# =============================================================================

$ErrorActionPreference = "Stop"

function Write-Info     { param($Message) Write-Host "[INFO] $Message" -ForegroundColor Blue }
function Write-Success  { param($Message) Write-Host "[SUCCESS] $Message" -ForegroundColor Green }
function Write-Warn     { param($Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-ErrorMsg { param($Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

$LayerDir = Join-Path $ProjectRoot "layer"
$PackagesDir = Join-Path $ProjectRoot "packages"
$RequirementsFile = Join-Path $ProjectRoot "src\processor\requirements.txt"
$OutputZip = Join-Path $PackagesDir "dependencies-layer.zip"

# Fixed timestamp used to normalize all files inside the ZIP
$FixedTimestamp = Get-Date "2020-01-01T00:00:00Z"

Write-Info "Building Lambda layer (deterministic zip)..."
Write-Info "Project root: $ProjectRoot"

New-Item -ItemType Directory -Force -Path (Join-Path $LayerDir "python") | Out-Null
New-Item -ItemType Directory -Force -Path $PackagesDir | Out-Null

# Clean previous builds
if (Test-Path (Join-Path $LayerDir "python\*")) {
    Remove-Item -Recurse -Force (Join-Path $LayerDir "python\*")
}
if (Test-Path $OutputZip) {
    Remove-Item -Force $OutputZip
}

if (-not (Test-Path $RequirementsFile)) {
    Write-ErrorMsg "Requirements file not found: $RequirementsFile"
    exit 1
}

try { $null = Get-Command pip -ErrorAction Stop }
catch {
    Write-ErrorMsg "pip not found. Install Python/pip before running this script."
    exit 1
}

$PythonDir = Join-Path $LayerDir "python"

Write-Info "Installing dependencies from: $RequirementsFile"

# IMPORTANT:
# - On Windows, the --platform manylinux... install often fails (as expected).
# - We try it first (useful if pip supports it in your environment), then fallback.
$installOk = $false
pip install --target $PythonDir --platform manylinux2014_x86_64 --implementation cp --python-version 3.11 --only-binary=:all: --upgrade -r $RequirementsFile 2>$null
if ($LASTEXITCODE -eq 0) {
    $installOk = $true
} else {
    Write-Warn "Platform-specific install failed; falling back to standard pip install."
    pip install --target $PythonDir --upgrade -r $RequirementsFile
    if ($LASTEXITCODE -eq 0) {
        $installOk = $true
    }
}

if (-not $installOk) {
    Write-ErrorMsg "pip install failed. Could not build Lambda dependencies layer."
    exit 1
}

$installedFiles = @(Get-ChildItem -Path $PythonDir -Recurse -File -ErrorAction SilentlyContinue)
if ($installedFiles.Count -eq 0) {
    Write-ErrorMsg "No dependencies were installed in layer/python. Build aborted."
    exit 1
}

Write-Info "Cleaning up __pycache__ and *.pyc..."
Get-ChildItem -Path $LayerDir -Recurse -Directory -Filter "__pycache__" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $LayerDir -Recurse -File -Include "*.pyc","*.pyo" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

Write-Info "Normalizing timestamps to $($FixedTimestamp.ToString('o'))..."
Get-ChildItem -Path $PythonDir -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        $_.LastWriteTimeUtc  = $FixedTimestamp
        $_.CreationTimeUtc   = $FixedTimestamp
        $_.LastAccessTimeUtc = $FixedTimestamp
    } catch { }
}

# Deterministic ZIP builder:
# - stable ordering of entries (sorted by relative path)
# - fixed entry LastWriteTime
# - no Compress-Archive (not deterministic)
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function New-DeterministicZip {
    param(
        [Parameter(Mandatory=$true)][string]$SourceDir,
        [Parameter(Mandatory=$true)][string]$ZipPath,
        [Parameter(Mandatory=$true)][datetime]$FixedTs
    )

    if (Test-Path $ZipPath) { Remove-Item -Force $ZipPath }

    $base = (Get-Item $SourceDir).FullName.TrimEnd('\')
    $files = Get-ChildItem -Path $SourceDir -Recurse -File -Force |
        ForEach-Object {
            $rel = $_.FullName.Substring($base.Length).TrimStart('\')
            $rel = $rel -replace '\\', '/'
            [PSCustomObject]@{ Full = $_.FullName; Rel = $rel }
        } | Sort-Object -Property Rel

    $zipStream = [System.IO.File]::Open($ZipPath, [System.IO.FileMode]::CreateNew)
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($zipStream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            foreach ($f in $files) {
                # Use Optimal; if you still get differences, switch to NoCompression for debugging.
                $entry = $zip.CreateEntry($f.Rel, [System.IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = [System.DateTimeOffset]::new($FixedTs)

                $entryStream = $entry.Open()
                try {
                    $inStream = [System.IO.File]::OpenRead($f.Full)
                    try { $inStream.CopyTo($entryStream) }
                    finally { $inStream.Dispose() }
                } finally {
                    $entryStream.Dispose()
                }
            }
        } finally {
            $zip.Dispose()
        }
    } finally {
        $zipStream.Dispose()
    }
}

Write-Info "Creating ZIP archive..."
# IMPORTANT: Python Lambda layers require dependencies under the "python/"
# prefix inside the ZIP. We zip from $LayerDir (not $PythonDir) to preserve
# the required folder structure.
New-DeterministicZip -SourceDir $LayerDir -ZipPath $OutputZip -FixedTs $FixedTimestamp

# Validate ZIP layout: at least one entry must live under "python/".
$hasPythonPrefix = $false
$zipRead = [System.IO.Compression.ZipFile]::OpenRead($OutputZip)
try {
    foreach ($entry in $zipRead.Entries) {
        if ($entry.FullName.StartsWith("python/") -or $entry.FullName.StartsWith("python\")) {
            $hasPythonPrefix = $true
            break
        }
    }
} finally {
    $zipRead.Dispose()
}

if (-not $hasPythonPrefix) {
    Write-ErrorMsg "Invalid layer ZIP layout: missing 'python/' prefix. Build aborted."
    exit 1
}

$hash = (Get-FileHash $OutputZip -Algorithm SHA256).Hash
$sizeKb = [math]::Round(((Get-Item $OutputZip).Length / 1KB), 2)

Write-Success "Layer built successfully!"
Write-Info "Output: $OutputZip ($sizeKb KB)"
Write-Info "SHA256: $hash"

Remove-Item -Recurse -Force $LayerDir -ErrorAction SilentlyContinue

Write-Host ""
Write-Success "Lambda layer is ready for deployment."
