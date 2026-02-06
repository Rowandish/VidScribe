#!/usr/bin/env pwsh
# =============================================================================
# 🏥 VidScribe - Healthy Monitor Script
# =============================================================================
# Checks for errors in the last 7 days:
# 1. Failed videos in DynamoDB
# 2. Messages in the Dead Letter Queue (DLQ)
# 3. Error logs in all Lambda functions
# =============================================================================

param(
    [int]$DaysBack = 7,
    [string]$ProjectName = "vidscribe",
    [string]$Stage = "prod"
)

$Prefix = "$ProjectName-$Stage"

function Write-Header {
    param([string]$Title)
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Gray
    Write-Host "$Title" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Gray
}

Write-Host "
   __  __             _ _             
  |  \/  |           (_) |            
  | \  / | ___  _ __  _| |_ ___  _ __ 
  | |\/| |/ _ \| '_ \| | __/ _ \| '__|
  | |  | | (_) | | | | | || (_) | |   
  |_|  |_|\___/|_| |_|_|\__\___/|_|   
                                      
  🏥 SYSTEM HEALTH CHECK (Last $DaysBack days)
" -ForegroundColor Magenta

# -----------------------------------------------------------------------------
# 1. DynamoDB Failures
# -----------------------------------------------------------------------------
Write-Header "1. DynamoDB Errors (Status = FAILED)"

$TableName = "$Prefix-videos"
try {
    # Scan for status=FAILED
    $Scan = aws dynamodb scan `
        --table-name $TableName `
        --filter-expression "#s = :f" `
        --expression-attribute-names '{"#s": "status"}' `
        --expression-attribute-values '{":f": {"S": "FAILED"}}' `
        --projection-expression "video_id, title, channel_title, failure_reason, failed_at" `
        --output json | ConvertFrom-Json

    if ($Scan.Count -gt 0) {
        Write-Host "found $($Scan.Count) failed videos." -ForegroundColor Red
        foreach ($item in $Scan.Items) {
            Write-Host "   - [$($item.failed_at.S)] $($item.title.S) ($($item.video_id.S))" -ForegroundColor Yellow
            Write-Host "     Reason: $($item.failure_reason.S)" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "No failed videos found." -ForegroundColor Green
    }
} catch {
    Write-Host "Error checking DynamoDB table '$TableName': $_" -ForegroundColor Red
}

# -----------------------------------------------------------------------------
# 2. SQS Dead Letter Queue
# -----------------------------------------------------------------------------
Write-Header "2. SQS Dead Letter Queue (DLQ)"

$DlqName = "$Prefix-video-dlq"
try {
    $QueueUrl = aws sqs get-queue-url --queue-name $DlqName --query 'QueueUrl' --output text 2>$null
    
    if ($QueueUrl) {
        $Attribs = aws sqs get-queue-attributes --queue-url $QueueUrl --attribute-names ApproximateNumberOfMessages --output json | ConvertFrom-Json
        $Count = [int]$Attribs.Attributes.ApproximateNumberOfMessages
        
        if ($Count -gt 0) {
            Write-Host "⚠️  DLQ is NOT empty!" -ForegroundColor Red
            Write-Host "   Pending Messages: $Count" -ForegroundColor Yellow
            Write-Host "   Run: aws sqs receive-message --queue-url $QueueUrl --max-number-of-messages 10" -ForegroundColor Gray
        } else {
            Write-Host "DLQ is empty." -ForegroundColor Green
        }
    } else {
        Write-Host "DLQ '$DlqName' not found." -ForegroundColor Red
    }
} catch {
    Write-Host "Error checking SQS: $_" -ForegroundColor Red
}

# -----------------------------------------------------------------------------
# 3. Lambda Logs
# -----------------------------------------------------------------------------
Write-Header "3. Lambda Error Logs"

$StartMs = [int64]((Get-Date).AddDays(-$DaysBack).ToUniversalTime() - (Get-Date "1970-01-01").ToUniversalTime()).TotalMilliseconds

$Functions = @("poller", "processor", "newsletter")

foreach ($func in $Functions) {
    $LogGroup = "/aws/lambda/$Prefix-$func"
    Write-Host "`nChecking $LogGroup..." -ForegroundColor Cyan
    
    try {
        # Filter for ERROR or Exception
        $Events = aws logs filter-log-events `
            --log-group-name $LogGroup `
            --start-time $StartMs `
            --filter-pattern '"?ERROR" "?Exception" "?Fail"' `
            --limit 5 `
            --output json 2>$null | ConvertFrom-Json

        if ($Events -and $Events.events -and $Events.events.Count -gt 0) {
            Write-Host "Found $($Events.events.Count) recent errors:" -ForegroundColor Red
            foreach ($e in $Events.events) {
                # Truncate message
                $msg = $e.message.Trim()
                if ($msg.Length -gt 150) { $msg = $msg.Substring(0, 150) + "..." }
                Write-Host "   - $([timezone]::CurrentTimeZone.ToLocalTime([datetimeoffset]::FromUnixTimeMilliseconds($e.timestamp))) : $msg" -ForegroundColor Yellow
            }
        } else {
            Write-Host "No obvious errors found." -ForegroundColor Green
        }
    } catch {
        Write-Host "   (Log group might not exist yet or no permissions)" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "🏥 Check Complete" -ForegroundColor Magenta
