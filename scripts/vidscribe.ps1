#!/usr/bin/env pwsh
# =============================================================================
# 🚀 VidScribe - Unified Workflow Script
# =============================================================================
# Process YouTube videos from URL to Newsletter in one command.
#
# Usage:
#   .\vidscribe.ps1 -Urls "https://youtube.com/watch?v=abc123"
#   .\vidscribe.ps1 -Urls "abc123","def456"
#   .\vidscribe.ps1 -Urls "url1" -SkipNewsletter
#   .\vidscribe.ps1 -TestNewsletter
# =============================================================================

param(
    [Parameter(Position=0)]
    [string[]]$Urls,

    [switch]$SkipNewsletter,
    [switch]$TestNewsletter,
    [int]$WaitTimeout = 300,
    [string]$QueueName = "vidscribe-prod-video-queue",
    [string]$ProcessorLogGroup = "/aws/lambda/vidscribe-prod-processor",
    [string]$NewsletterFunc = "vidscribe-prod-newsletter",
    [string]$TableName = "vidscribe-prod-videos"
)

$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

function Write-Step {
    param([string]$Message, [string]$Emoji = "▶")
    Write-Host ""
    Write-Host "$Emoji $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "   ✅ $Message" -ForegroundColor Green
}

function Write-ErrorMsg {
    param([string]$Message)
    Write-Host "   ❌ $Message" -ForegroundColor Red
}

function Write-Warning {
    param([string]$Message)
    Write-Host "   ⚠️  $Message" -ForegroundColor Yellow
}

function Write-Info {
    param([string]$Message)
    Write-Host "   $Message" -ForegroundColor Gray
}

function Extract-VideoId {
    param([string]$Input)
    
    # If it's already just an ID (11 chars, alphanumeric with - and _)
    if ($Input -match "^[a-zA-Z0-9_-]{11}$") {
        return $Input
    }
    
    # Extract from various YouTube URL formats
    if ($Input -match "(?:youtube\.com/watch\?v=|youtu\.be/|youtube\.com/embed/|youtube\.com/v/)([a-zA-Z0-9_-]{11})") {
        return $Matches[1]
    }
    
    # If nothing matches, return as-is and let YouTube API handle it
    return $Input
}

function Show-Banner {
    Write-Host @"

   ░█░█░▀█▀░█▀▄░█▀▀░█▀▀░█▀▄░▀█▀░█▀▄░█▀▀
   ░▀▄▀░░█░░█░█░▀▀█░█░░░█▀▄░░█░░█▀▄░█▀▀
   ░░▀░░▀▀▀░▀▀░░▀▀▀░▀▀▀░▀░▀░▀▀▀░▀▀░░▀▀▀
   
   📺 YouTube to Newsletter Pipeline
"@ -ForegroundColor Magenta
}

# -----------------------------------------------------------------------------
# Test Newsletter Mode
# -----------------------------------------------------------------------------

function Invoke-TestNewsletter {
    Write-Step -Message "Test Newsletter Mode" -Emoji "🧪"
    
    $now = Get-Date -Format "yyyy-MM-ddTHH:mm:ssK"
    $ttl = [int](Get-Date).AddDays(30).ToUniversalTime().Subtract([datetime]'1970-01-01').TotalSeconds
    $videoId = "test-$(Get-Random -Minimum 1000 -Maximum 9999)"
    
    Write-Info "Inserting test summary..."
    Write-Info "Video ID: $videoId"
    
    $item = @{
        pk = @{ S = "SUMMARY#$videoId" }
        sk = @{ S = "DATA" }
        gsi1pk = @{ S = "SUMMARY" }
        gsi1sk = @{ S = $now }
        video_id = @{ S = $videoId }
        title = @{ S = "🧪 Test Video - VidScribe Pipeline Test" }
        channel_title = @{ S = "VidScribe Test Channel" }
        summary = @{ S = @"
Questo è un video di test per verificare che il sistema VidScribe funzioni correttamente.

**Funzionalità testate:**
- Inserimento dati in DynamoDB
- Invocazione Lambda Newsletter
- Formattazione HTML email
- Invio via SES o Gmail

Se ricevi questa email, il sistema è operativo! 🎉
"@ }
        published_at = @{ S = $now }
        summarized_at = @{ S = $now }
        ttl = @{ N = $ttl.ToString() }
    }

    try {
        aws dynamodb put-item `
            --table-name $TableName `
            --item ($item | ConvertTo-Json -Depth 10 -Compress) `
            --no-cli-pager | Out-Null
        Write-Success "Test data inserted"
    } catch {
        Write-ErrorMsg "Failed to insert test data: $_"
        exit 1
    }

    Write-Step -Message "Sending Newsletter" -Emoji "📧"
    
    try {
        $tempFile = [System.IO.Path]::GetTempFileName()
        aws lambda invoke `
            --function-name $NewsletterFunc `
            --payload '{}' `
            --cli-binary-format raw-in-base64-out `
            $tempFile `
            --no-cli-pager | Out-Null
        
        $response = Get-Content $tempFile -Raw | ConvertFrom-Json
        Remove-Item $tempFile -ErrorAction SilentlyContinue
        
        if ($response.statusCode -eq 200) {
            Write-Success "Newsletter sent!"
            $body = $response.body | ConvertFrom-Json
            Write-Info "Summaries: $($body.summaries_count)"
            Write-Info "Recipient: $($body.recipient)"
        } else {
            Write-ErrorMsg "Newsletter failed: $($response.body)"
            exit 1
        }
    } catch {
        Write-ErrorMsg "Failed to invoke newsletter: $_"
        exit 1
    }

    Write-Host ""
    Write-Host "🎉 Test complete! Check your inbox." -ForegroundColor Green
    Write-Host ""
    Write-Info "To clean up: aws dynamodb delete-item --table-name $TableName --key '{`"pk`":{`"S`":`"SUMMARY#$videoId`"},`"sk`":{`"S`":`"DATA`"}}'"
}

# -----------------------------------------------------------------------------
# Main Workflow
# -----------------------------------------------------------------------------

function Invoke-VideoWorkflow {
    param([string[]]$VideoIds)
    
    # 1. Check AWS Resources
    Write-Step -Message "Checking AWS Resources" -Emoji "🔍"
    
    try {
        $QueueUrl = aws sqs get-queue-url --queue-name $QueueName --query 'QueueUrl' --output text 2>$null
        if (-not $QueueUrl) { throw "Queue not found" }
        Write-Success "Queue: $QueueName"
    } catch {
        Write-ErrorMsg "Failed to find SQS queue. Is the infrastructure deployed?"
        Write-Info "Run: cd infra && terraform apply"
        exit 1
    }

    $StartTime = [int64]((Get-Date).ToUniversalTime() - (Get-Date "1970-01-01").ToUniversalTime()).TotalMilliseconds

    # 2. Inject Videos
    Write-Step -Message "Injecting $($VideoIds.Count) video(s) into queue" -Emoji "💉"
    
    foreach ($vid in $VideoIds) {
        $body = @{
            video_id      = $vid
            title         = "Manual: $vid"
            channel_id    = "MANUAL"
            channel_title = "Manual Trigger"
            published_at  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        } | ConvertTo-Json -Compress

        try {
            aws sqs send-message --queue-url $QueueUrl --message-body $body --no-cli-pager | Out-Null
            Write-Info "→ $vid"
        } catch {
            Write-ErrorMsg "Failed to inject $vid"
        }
    }
    Write-Success "All videos queued"

    # 3. Monitor Processing
    Write-Step -Message "Waiting for processing (max ${WaitTimeout}s)" -Emoji "⏳"
    
    $Pending = [System.Collections.Generic.HashSet[string]]::new([string[]]$VideoIds)
    $Elapsed = 0
    $PollInterval = 5

    while ($Pending.Count -gt 0 -and $Elapsed -lt $WaitTimeout) {
        Start-Sleep -Seconds $PollInterval
        $Elapsed += $PollInterval
        
        try {
            $Logs = aws logs filter-log-events `
                --log-group-name $ProcessorLogGroup `
                --start-time $StartTime `
                --output json 2>$null | ConvertFrom-Json
            
            if ($Logs -and $Logs.events) {
                foreach ($event in $Logs.events) {
                    $msg = $event.message
                    
                    if ($msg -match "Successfully processed video: (.+)") {
                        $processedId = $Matches[1].Trim()
                        if ($Pending.Contains($processedId)) {
                            $Pending.Remove($processedId) | Out-Null
                            Write-Success "Processed: $processedId"
                        }
                    }
                    
                    if ($msg -match "Error|Failed|Exception" -and $msg -match "video.*?([a-zA-Z0-9_-]{11})") {
                        $failedId = $Matches[1]
                        if ($Pending.Contains($failedId)) {
                            $Pending.Remove($failedId) | Out-Null
                            Write-ErrorMsg "Failed: $failedId"
                        }
                    }
                }
            }
        } catch {
            # Log group might not exist yet
        }
        
        Write-Host "." -NoNewline -ForegroundColor DarkGray
    }

    Write-Host ""
    
    if ($Pending.Count -gt 0) {
        Write-Warning "Timeout! Still pending: $($Pending -join ', ')"
        Write-Info "Videos may still be processing. Check CloudWatch logs."
    } else {
        Write-Success "All videos processed!"
    }

    # 4. Send Newsletter
    if (-not $SkipNewsletter) {
        Write-Step -Message "Sending Newsletter" -Emoji "📧"
        
        try {
            $tempFile = [System.IO.Path]::GetTempFileName()
            aws lambda invoke `
                --function-name $NewsletterFunc `
                --cli-binary-format raw-in-base64-out `
                $tempFile `
                --no-cli-pager | Out-Null
            
            $response = Get-Content $tempFile -Raw | ConvertFrom-Json
            Remove-Item $tempFile -ErrorAction SilentlyContinue
            
            if ($response.statusCode -eq 200) {
                Write-Success "Newsletter sent!"
                $body = $response.body | ConvertFrom-Json
                Write-Info "Summaries: $($body.summaries_count)"
            } elseif ($response.errorMessage) {
                Write-ErrorMsg "Newsletter error: $($response.errorMessage)"
            } else {
                Write-Warning "Newsletter response: $($response | ConvertTo-Json -Compress)"
            }
        } catch {
            Write-ErrorMsg "Failed to invoke newsletter: $_"
        }
    } else {
        Write-Info "Skipping newsletter (use without -SkipNewsletter to send)"
    }

    Write-Host ""
    Write-Host "🎉 WORKFLOW COMPLETE" -ForegroundColor Magenta
    Write-Host ""
}

# -----------------------------------------------------------------------------
# Entry Point
# -----------------------------------------------------------------------------

Show-Banner

if ($TestNewsletter) {
    Invoke-TestNewsletter
    exit 0
}

if (-not $Urls -or $Urls.Count -eq 0) {
    Write-ErrorMsg "No URLs provided!"
    Write-Host ""
    Write-Host "Usage:" -ForegroundColor Yellow
    Write-Host "  .\vidscribe.ps1 -Urls 'https://youtube.com/watch?v=abc123'" -ForegroundColor Gray
    Write-Host "  .\vidscribe.ps1 -Urls 'id1','id2' -SkipNewsletter" -ForegroundColor Gray
    Write-Host "  .\vidscribe.ps1 -TestNewsletter" -ForegroundColor Gray
    Write-Host ""
    exit 1
}

# Extract video IDs from URLs
$VideoIds = $Urls | ForEach-Object { Extract-VideoId $_ }

Write-Info "Video IDs: $($VideoIds -join ', ')"

Invoke-VideoWorkflow -VideoIds $VideoIds
