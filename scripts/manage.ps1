#!/usr/bin/env pwsh
# =============================================================================
# 🛠️  VidScribe Management Tool
# =============================================================================
# Unified management console for VidScribe operations.
#
# Usage:
#   .\manage.ps1 <command> [subcommand] [options]
#
# Commands:
#   channels   list | add <ID> | remove <ID> | clear
#   newsletter frequency <daily|weekly|monthly> | test <VIDEO_URL>
#   errors     Show recent errors
#   logs       <poller|processor|newsletter|cleanup> [-Lines N]
#   apikeys    update
#   info       System status dashboard
#   cleanup    run | status
#   retry      list
#   help       Show this help
# =============================================================================

param(
    [Parameter(Position=0)]
    [string]$Command,

    [Parameter(Position=1)]
    [string]$SubCommand,

    [Parameter(Position=2)]
    [string]$Argument,

    [int]$Lines = 50,
    [int]$DaysBack = 7,
    [string]$ProjectName = "vidscribe",
    [string]$Stage = "prod"
)

$ErrorActionPreference = "Stop"

# =============================================================================
# Configuration
# =============================================================================

$Script:SSM_PREFIX = "/$ProjectName"
$Script:TABLE_NAME = "$ProjectName-$Stage-videos"
$Script:QUEUE_NAME = "$ProjectName-$Stage-video-queue"
$Script:DLQ_NAME   = "$ProjectName-$Stage-video-dlq"

$Script:LAMBDA_POLLER     = "$ProjectName-$Stage-poller"
$Script:LAMBDA_PROCESSOR  = "$ProjectName-$Stage-processor"
$Script:LAMBDA_NEWSLETTER = "$ProjectName-$Stage-newsletter"
$Script:LAMBDA_CLEANUP    = "$ProjectName-$Stage-cleanup"

$Script:LOG_GROUPS = @{
    "poller"     = "/aws/lambda/$Script:LAMBDA_POLLER"
    "processor"  = "/aws/lambda/$Script:LAMBDA_PROCESSOR"
    "newsletter" = "/aws/lambda/$Script:LAMBDA_NEWSLETTER"
    "cleanup"    = "/aws/lambda/$Script:LAMBDA_CLEANUP"
}

# =============================================================================
# UI Helpers — Modern Aesthetic
# =============================================================================

function Write-Banner {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor DarkCyan
    Write-Host "  ║                                                              ║" -ForegroundColor DarkCyan
    Write-Host "  ║   " -NoNewline -ForegroundColor DarkCyan
    Write-Host "🛠️  VidScribe Management Tool" -NoNewline -ForegroundColor Cyan
    Write-Host "                               ║" -ForegroundColor DarkCyan
    Write-Host "  ║                                                              ║" -ForegroundColor DarkCyan
    Write-Host "  ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor DarkCyan
    Write-Host ""
}

function Write-Section {
    param([string]$Title, [string]$Icon = "▸")
    Write-Host ""
    Write-Host "  $Icon " -NoNewline -ForegroundColor Magenta
    Write-Host "$Title" -ForegroundColor White
    Write-Host "  $('─' * 60)" -ForegroundColor DarkGray
}

function Write-Row {
    param([string]$Label, [string]$Value, [string]$Color = "White")
    $padding = 22 - $Label.Length
    if ($padding -lt 1) { $padding = 1 }
    Write-Host "    $Label" -NoNewline -ForegroundColor Gray
    Write-Host "$(' ' * $padding)$Value" -ForegroundColor $Color
}

function Write-OK   { param([string]$Msg); Write-Host "    ✅ $Msg" -ForegroundColor Green }
function Write-Err  { param([string]$Msg); Write-Host "    ❌ $Msg" -ForegroundColor Red }
function Write-Warn { param([string]$Msg); Write-Host "    ⚠️  $Msg" -ForegroundColor Yellow }
function Write-Inf  { param([string]$Msg); Write-Host "    ℹ️  $Msg" -ForegroundColor DarkCyan }

function Write-TableHeader {
    param([string[]]$Columns, [int[]]$Widths)
    $line = "    "
    for ($i = 0; $i -lt $Columns.Count; $i++) {
        $line += $Columns[$i].PadRight($Widths[$i])
    }
    Write-Host $line -ForegroundColor Cyan
    $separator = "    "
    for ($i = 0; $i -lt $Widths.Count; $i++) {
        $separator += ('─' * ($Widths[$i] - 1)) + " "
    }
    Write-Host $separator -ForegroundColor DarkGray
}

function Write-TableRow {
    param([string[]]$Values, [int[]]$Widths, [string]$Color = "White")
    $line = "    "
    for ($i = 0; $i -lt $Values.Count; $i++) {
        $val = if ($Values[$i].Length -gt ($Widths[$i] - 2)) {
            $Values[$i].Substring(0, $Widths[$i] - 5) + "..."
        } else { $Values[$i] }
        $line += $val.PadRight($Widths[$i])
    }
    Write-Host $line -ForegroundColor $Color
}

function Confirm-Action {
    param([string]$Message)
    Write-Host ""
    Write-Host "    $Message" -NoNewline -ForegroundColor Yellow
    Write-Host " [y/N] " -NoNewline -ForegroundColor DarkGray
    $response = Read-Host
    return $response -match "^[yY]"
}

# =============================================================================
# SSM Helpers
# =============================================================================

function Get-SSMValue {
    param([string]$Name, [switch]$Secure)
    try {
        $paramName = "$Script:SSM_PREFIX/$Name"
        if ($Secure) {
            $result = aws ssm get-parameter --name $paramName --with-decryption --output json 2>$null | ConvertFrom-Json
        } else {
            $result = aws ssm get-parameter --name $paramName --output json 2>$null | ConvertFrom-Json
        }
        return $result.Parameter.Value
    } catch {
        return $null
    }
}

function Set-SSMValue {
    param([string]$Name, [string]$Value, [string]$Type = "String")
    aws ssm put-parameter `
        --name "$Script:SSM_PREFIX/$Name" `
        --value $Value `
        --type $Type `
        --overwrite `
        --output json 2>$null | Out-Null
}

function Get-ChannelName {
    param([string]$ChannelId)
    try {
        $apiKey = Get-SSMValue -Name "youtube_api_key" -Secure
        if (-not $apiKey -or $apiKey -eq "PLACEHOLDER_REPLACE_ME") { return "?" }
        $url = "https://www.googleapis.com/youtube/v3/channels?part=snippet&id=$ChannelId&key=$apiKey&fields=items/snippet/title"
        $resp = Invoke-RestMethod -Uri $url -TimeoutSec 5
        if ($resp.items.Count -gt 0) { return $resp.items[0].snippet.title }
        return "Unknown"
    } catch {
        return "?"
    }
}
function Extract-VideoId {
    param([string]$Url)
    if ($Url -match "^[a-zA-Z0-9_-]{11}$") { return $Url }
    if ($Url -match "(?:youtube\.com/watch\?v=|youtu\.be/|youtube\.com/embed/|youtube\.com/v/)([a-zA-Z0-9_-]{11})") {
        return $Matches[1]
    }
    return $Url
}

function Get-VideoProcessingStatus {
    param([string]$VideoId)
    try {
        $keyJson = "{`"pk`":{`"S`":`"VIDEO#$VideoId`"},`"sk`":{`"S`":`"METADATA`"}}"
        $item = aws dynamodb get-item `
            --table-name $Script:TABLE_NAME `
            --key $keyJson `
            --consistent-read `
            --output json 2>$null | ConvertFrom-Json

        return $item.Item.status.S
    } catch {
        return $null
    }
}

function Get-VideoProcessingDetails {
    param([string]$VideoId)
    try {
        $keyJson = "{`"pk`":{`"S`":`"VIDEO#$VideoId`"},`"sk`":{`"S`":`"METADATA`"}}"
        $item = aws dynamodb get-item `
            --table-name $Script:TABLE_NAME `
            --key $keyJson `
            --consistent-read `
            --output json 2>$null | ConvertFrom-Json

        if (-not $item -or -not $item.Item) { return $null }

        return [PSCustomObject]@{
            Status      = $item.Item.status.S
            FailureReason = $item.Item.failure_reason.S
            Error       = $item.Item.error.S
            FailedAt    = $item.Item.failed_at.S
            NextRetryAt = $item.Item.next_retry_at.S
        }
    } catch {
        return $null
    }
}

function Get-ProcessorLogExcerptForVideo {
    param(
        [string]$VideoId,
        [int64]$StartTime,
        [int]$MaxLines = 8
    )
    try {
        $logGroup = $Script:LOG_GROUPS["processor"]
        $logs = aws logs filter-log-events `
            --log-group-name $logGroup `
            --start-time $StartTime `
            --output json 2>$null | ConvertFrom-Json

        if (-not $logs -or -not $logs.events) { return @() }

        $matches = @()
        foreach ($event in $logs.events) {
            $msg = [string]$event.message
            if ($msg -and $msg.Contains($VideoId)) {
                $line = ($msg -replace "`r", " " -replace "`n", " ").Trim()
                if ($line) { $matches += $line }
            }
        }

        if ($matches.Count -eq 0) { return @() }
        return @($matches | Select-Object -Last $MaxLines)
    } catch {
        return @()
    }
}

function Write-VideoFailureDiagnostics {
    param(
        [string]$VideoId,
        [int64]$StartTime,
        [string]$Status = $null
    )

    $details = Get-VideoProcessingDetails -VideoId $VideoId
    if (-not $Status -and $details -and $details.Status) { $Status = $details.Status }
    if (-not $Status) { $Status = "FAILED" }

    Write-Err "Failed: $VideoId ($Status)"

    if ($details) {
        if ($details.FailureReason) { Write-Inf "Reason: $($details.FailureReason)" }
        if ($details.Error) {
            $err = [string]$details.Error
            if ($err.Length -gt 220) { $err = $err.Substring(0, 217) + "..." }
            Write-Inf "Error: $err"
        }
        if ($details.NextRetryAt) { Write-Inf "Next retry at: $($details.NextRetryAt)" }
    }

    $lines = Get-ProcessorLogExcerptForVideo -VideoId $VideoId -StartTime $StartTime
    if ($lines.Count -gt 0) {
        Write-Host "      Processor log excerpt for ${VideoId}:" -ForegroundColor DarkCyan
        foreach ($line in $lines) {
            Write-Host "      • $line" -ForegroundColor Gray
        }
    }
}


# =============================================================================
# Command: channels
# =============================================================================

function Invoke-Channels {
    switch ($SubCommand) {
        "list"   { Invoke-ChannelsList }
        "add"    { Invoke-ChannelsAdd }
        "remove" { Invoke-ChannelsRemove }
        "clear"  { Invoke-ChannelsClear }
        default  { Invoke-ChannelsList }
    }
}

function Invoke-ChannelsList {
    Write-Section "Monitored Channels" "📺"

    $raw = Get-SSMValue -Name "youtube_channels"
    if (-not $raw) {
        Write-Warn "Could not read channels configuration"
        return
    }

    $channels = $raw | ConvertFrom-Json
    if ($channels.Count -eq 0) {
        Write-Inf "No channels configured"
        return
    }

    Write-TableHeader -Columns @("#", "Channel ID", "Name") -Widths @(5, 28, 30)

    $idx = 1
    foreach ($ch in $channels) {
        $name = Get-ChannelName -ChannelId $ch
        Write-TableRow -Values @("$idx", $ch, $name) -Widths @(5, 28, 30)
        $idx++
    }
    Write-Host ""
    Write-Inf "Total: $($channels.Count) channel(s)"
}

function Invoke-ChannelsAdd {
    if (-not $Argument) {
        Write-Err "Usage: .\manage.ps1 channels add <CHANNEL_ID>"
        return
    }

    Write-Section "Add Channel" "➕"

    $raw = Get-SSMValue -Name "youtube_channels"
    $channels = if ($raw) { $raw | ConvertFrom-Json } else { @() }

    if ($channels -contains $Argument) {
        Write-Warn "Channel $Argument is already monitored"
        return
    }

    $name = Get-ChannelName -ChannelId $Argument
    Write-Inf "Channel: $Argument ($name)"

    $channels += $Argument
    $json = $channels | ConvertTo-Json -Compress
    Set-SSMValue -Name "youtube_channels" -Value $json
    Write-OK "Channel added successfully. Total: $($channels.Count)"
}

function Invoke-ChannelsRemove {
    if (-not $Argument) {
        Write-Err "Usage: .\manage.ps1 channels remove <CHANNEL_ID>"
        return
    }

    Write-Section "Remove Channel" "➖"

    $raw = Get-SSMValue -Name "youtube_channels"
    $channels = if ($raw) { @($raw | ConvertFrom-Json) } else { @() }

    if ($channels -notcontains $Argument) {
        Write-Warn "Channel $Argument is not in the monitored list"
        return
    }

    $name = Get-ChannelName -ChannelId $Argument
    Write-Inf "Removing: $Argument ($name)"

    $channels = @($channels | Where-Object { $_ -ne $Argument })
    $json = if ($channels.Count -eq 0) { "[]" } else { $channels | ConvertTo-Json -Compress }
    Set-SSMValue -Name "youtube_channels" -Value $json
    Write-OK "Channel removed. Remaining: $($channels.Count)"
}

function Invoke-ChannelsClear {
    Write-Section "Clear All Channels" "🗑️"

    $raw = Get-SSMValue -Name "youtube_channels"
    $channels = if ($raw) { @($raw | ConvertFrom-Json) } else { @() }

    if ($channels.Count -eq 0) {
        Write-Inf "No channels to remove"
        return
    }

    Write-Warn "This will remove all $($channels.Count) monitored channels"

    if (-not (Confirm-Action "Are you sure?")) {
        Write-Inf "Cancelled"
        return
    }

    Set-SSMValue -Name "youtube_channels" -Value "[]"
    Write-OK "All channels removed"
}

# =============================================================================
# Command: email
# =============================================================================

function Invoke-Email {
    switch ($SubCommand) {
        "method" {
            if ($Argument -notin @("ses", "gmail")) {
                Write-Err "Usage: .\manage.ps1 email method <ses|gmail>"
                return
            }
            Write-Section "Email Method: $Argument" "📧"
            
            $useGmail = if ($Argument -eq "gmail") { "true" } else { "false" }
            
            # Update SSM
            Set-SSMValue -Name "use_gmail_smtp" -Value $useGmail
            Write-OK "Email method updated to $Argument"
        }
        "configure" {
            Write-Section "Configure Email" "📧"
            
            # Common settings
            $sender = Read-Host "    Sender Email (SES verified or Gmail address)"
            if ($sender) { Set-SSMValue -Name "sender_email" -Value $sender; Write-OK "Sender updated" }
            
            $dest = Read-Host "    Destination Email"
            if ($dest) { Set-SSMValue -Name "destination_email" -Value $dest; Write-OK "Destination updated" }
            
            # Gmail specific
            $useGmail = Get-SSMValue -Name "use_gmail_smtp"
            if ($useGmail -eq "true") {
                Write-Host ""
                Write-Inf "Gmail SMTP settings:"
                
                $gmailSender = Read-Host "    Gmail Address (usually same as Sender)"
                if ($gmailSender) { 
                    Set-SSMValue -Name "gmail_sender" -Value $gmailSender
                    Write-OK "Gmail sender updated"
                }
                
                $gmailPass = Read-Host "    Gmail App Password"
                if ($gmailPass) { 
                    Set-SSMValue -Name "gmail_app_password" -Value $gmailPass -Type "SecureString"
                    Write-OK "Gmail app password updated"
                }
            }
        }
        default {
            Write-Err "Usage: .\manage.ps1 email <method|configure>"
        }
    }
}

# =============================================================================
# Command: newsletter
# =============================================================================

function Invoke-Newsletter {
    switch ($SubCommand) {
        "frequency"    { Invoke-NewsletterFrequency }
        "test"         { Invoke-NewsletterTest }
        "test-insert"  { Invoke-NewsletterTestInsert }
        default        {
            Write-Err "Usage: .\manage.ps1 newsletter <frequency|test|test-insert> [value]"
        }
    }
}

function Invoke-NewsletterFrequency {
    Write-Section "Newsletter Frequency" "📬"

    $validFreqs = @{
        "daily"   = "rate(1 day)"
        "weekly"  = "rate(7 days)"
        "monthly" = "cron(0 9 1 * ? *)"
    }

    if (-not $Argument -or -not $validFreqs.ContainsKey($Argument)) {
        # Show current schedule
        try {
            $rule = aws events describe-rule --name "$Script:LAMBDA_NEWSLETTER-schedule" --output json 2>$null | ConvertFrom-Json
            Write-Row -Label "Current schedule" -Value $rule.ScheduleExpression -Color Cyan
        } catch {
            Write-Warn "Could not read current schedule"
        }
        Write-Host ""
        Write-Inf "Usage: .\manage.ps1 newsletter frequency <daily|weekly|monthly>"
        Write-Inf "Options: daily, weekly, monthly"
        return
    }

    $cronExpr = $validFreqs[$Argument]

    aws events put-rule `
        --name "$Script:LAMBDA_NEWSLETTER-schedule" `
        --schedule-expression $cronExpr `
        --state ENABLED `
        --output json 2>$null | Out-Null

    Write-OK "Newsletter schedule updated to: $Argument ($cronExpr)"
}

function Invoke-NewsletterTest {
    Write-Section "Send Test Newsletter" "📧"

    Write-Inf "Invoking newsletter Lambda..."
    $payload = @{ source = "manual-test"; "detail-type" = "Manual Test" } | ConvertTo-Json -Compress

    try {
        $tmpFile = [System.IO.Path]::GetTempFileName()
        aws lambda invoke `
            --function-name $Script:LAMBDA_NEWSLETTER `
            --payload $payload `
            --cli-binary-format raw-in-base64-out `
            $tmpFile 2>$null | Out-Null

        $response = Get-Content $tmpFile | ConvertFrom-Json
        Remove-Item $tmpFile -Force

        if ($response.statusCode -eq 200) {
            Write-OK "Test newsletter sent successfully"
            $body = $response.body | ConvertFrom-Json
            Write-Row -Label "Summaries" -Value $body.summaries_count -Color Cyan
            Write-Row -Label "Recipient" -Value $body.recipient -Color White
        } else {
            Write-Err "Newsletter invocation failed"
            if ($response.body) { Write-Inf $response.body }
        }
    } catch {
        Write-Err "Could not invoke newsletter Lambda: $_"
    }
}

function Invoke-NewsletterTestInsert {
    Write-Section "Insert Test Summary & Send Newsletter" "🧪"

    $now = Get-Date -Format "yyyy-MM-ddTHH:mm:ssK"
    $ttl = [int](Get-Date).AddDays(30).ToUniversalTime().Subtract([datetime]'1970-01-01').TotalSeconds
    $videoId = "test-$(Get-Random -Minimum 1000 -Maximum 9999)"

    Write-Inf "Inserting test summary (ID: $videoId)..."

    $item = @{
        pk = @{ S = "SUMMARY#$videoId" }
        sk = @{ S = "DATA" }
        gsi1pk = @{ S = "SUMMARY" }
        gsi1sk = @{ S = $now }
        video_id = @{ S = $videoId }
        title = @{ S = "🧪 Test Video - VidScribe Pipeline Test" }
        channel_title = @{ S = "VidScribe Test Channel" }
        summary = @{ S = @"
This is a test video to verify the VidScribe system works correctly.

**Features tested:**
- DynamoDB data insertion
- Newsletter Lambda invocation
- HTML email formatting
- Send via SES or Gmail

If you receive this email, the system is operational! 🎉
"@ }
        published_at = @{ S = $now }
        summarized_at = @{ S = $now }
        ttl = @{ N = $ttl.ToString() }
    }

    try {
        aws dynamodb put-item `
            --table-name $Script:TABLE_NAME `
            --item ($item | ConvertTo-Json -Depth 10 -Compress) `
            --no-cli-pager 2>$null | Out-Null
        Write-OK "Test data inserted"
    } catch {
        Write-Err "Failed to insert test data: $_"
        return
    }

    Write-Inf "Invoking newsletter Lambda..."
    try {
        $tmpFile = [System.IO.Path]::GetTempFileName()
        aws lambda invoke `
            --function-name $Script:LAMBDA_NEWSLETTER `
            --payload '{}' `
            --cli-binary-format raw-in-base64-out `
            $tmpFile `
            --no-cli-pager 2>$null | Out-Null

        $response = Get-Content $tmpFile -Raw | ConvertFrom-Json
        Remove-Item $tmpFile -Force

        if ($response.statusCode -eq 200) {
            Write-OK "Newsletter sent!"
            $body = $response.body | ConvertFrom-Json
            Write-Row -Label "Summaries" -Value $body.summaries_count -Color Cyan
            Write-Row -Label "Recipient" -Value $body.recipient -Color White
        } else {
            Write-Err "Newsletter failed: $($response.body)"
        }
    } catch {
        Write-Err "Could not invoke newsletter Lambda: $_"
    }

    Write-Host ""
    Write-Inf "Cleanup: aws dynamodb delete-item --table-name $Script:TABLE_NAME --key '{`"pk`":{`"S`":`"SUMMARY#$videoId`"},`"sk`":{`"S`":`"DATA`"}}'" 
}

# =============================================================================
# Command: errors
# =============================================================================

function Invoke-Errors {
    Write-Section "Error Report (last $DaysBack days)" "🏥"

    # 1. DynamoDB failed videos
    Write-Host ""
    Write-Host "    📊 " -NoNewline -ForegroundColor Yellow
    Write-Host "Failed Videos in DynamoDB" -ForegroundColor White

    try {
        $scanResult = aws dynamodb scan `
            --table-name $Script:TABLE_NAME `
            --filter-expression "#s = :failed OR #s = :permfailed" `
            --expression-attribute-names '{"#s":"status"}' `
            --expression-attribute-values '{":failed":{"S":"FAILED"},":permfailed":{"S":"PERMANENTLY_FAILED"}}' `
            --projection-expression "video_id, title, failure_reason, failed_at, retry_count, #s" `
            --output json 2>$null | ConvertFrom-Json

        $items = $scanResult.Items
        if ($items.Count -eq 0) {
            Write-OK "No failed videos found"
        } else {
            Write-TableHeader -Columns @("Video ID", "Title", "Reason", "Retries", "Status") -Widths @(14, 30, 22, 10, 20)
            foreach ($item in $items) {
                $status = if ($item.status.S) { $item.status.S } else { "FAILED" }
                $color = if ($status -eq "PERMANENTLY_FAILED") { "Red" } else { "Yellow" }
                Write-TableRow -Values @(
                    ($item.video_id.S ?? "?"),
                    ($item.title.S ?? "—"),
                    ($item.failure_reason.S ?? "?"),
                    ($item.retry_count.N ?? "0"),
                    $status
                ) -Widths @(14, 30, 22, 10, 20) -Color $color
            }
            Write-Host ""
            Write-Inf "Total failed: $($items.Count)"
        }
    } catch {
        Write-Err "Could not scan DynamoDB: $_"
    }

    # 2. DLQ messages
    Write-Host ""
    Write-Host "    📬 " -NoNewline -ForegroundColor Yellow
    Write-Host "Dead Letter Queue" -ForegroundColor White

    try {
        $queueUrl = (aws sqs get-queue-url --queue-name $Script:DLQ_NAME --output json 2>$null | ConvertFrom-Json).QueueUrl
        $attrs = (aws sqs get-queue-attributes --queue-url $queueUrl --attribute-names ApproximateNumberOfMessages --output json 2>$null | ConvertFrom-Json)
        $msgCount = [int]$attrs.Attributes.ApproximateNumberOfMessages

        if ($msgCount -eq 0) {
            Write-OK "DLQ is empty"
        } else {
            Write-Err "$msgCount message(s) in the Dead Letter Queue"
        }
    } catch {
        Write-Warn "Could not check DLQ"
    }

    # 3. Lambda errors (from CloudWatch)
    Write-Host ""
    Write-Host "    📋 " -NoNewline -ForegroundColor Yellow
    Write-Host "Recent Lambda Errors" -ForegroundColor White

    $startTime = [long](([DateTimeOffset]::UtcNow.AddDays(-$DaysBack)).ToUnixTimeMilliseconds())
    $endTime = [long](([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()))

    foreach ($func in @("poller", "processor", "newsletter", "cleanup")) {
        $logGroup = $Script:LOG_GROUPS[$func]
        try {
            $events = aws logs filter-log-events `
                --log-group-name $logGroup `
                --filter-pattern "ERROR" `
                --start-time $startTime `
                --end-time $endTime `
                --limit 5 `
                --output json 2>$null | ConvertFrom-Json

            $count = $events.events.Count
            if ($count -gt 0) {
                Write-Err "$func`: $count error(s)"
                foreach ($ev in $events.events | Select-Object -First 3) {
                    $msg = $ev.message.Trim()
                    Write-Host "       └─ $msg" -ForegroundColor DarkRed
                }
            } else {
                Write-OK "$func`: No errors"
            }
        } catch {
            Write-Inf "$func`: Log group not found (might not be deployed yet)"
        }
    }
}

# =============================================================================
# Command: logs
# =============================================================================

function Invoke-Logs {
    if (-not $SubCommand -or -not $Script:LOG_GROUPS.ContainsKey($SubCommand)) {
        Write-Section "CloudWatch Logs" "📋"
        Write-Err "Usage: .\manage.ps1 logs <poller|processor|newsletter|cleanup> [-Lines N]"
        Write-Inf "Available log groups:"
        foreach ($key in $Script:LOG_GROUPS.Keys) {
            Write-Host "      • $key" -ForegroundColor Cyan
        }
        return
    }

    $logGroup = $Script:LOG_GROUPS[$SubCommand]
    Write-Section "Logs: $SubCommand (last $Lines events)" "📋"

    try {
        aws logs tail $logGroup --since "1h" --format short 2>$null | Select-Object -Last $Lines | ForEach-Object {
            Write-Host "    $_" -ForegroundColor Gray
        }
    } catch {
        Write-Err "Could not tail logs for $logGroup"
        Write-Inf "Make sure the log group exists and you have permissions"
    }
}

# =============================================================================
# Command: apikeys
# =============================================================================

function Invoke-ApiKeys {
    Write-Section "API Key Management" "🔑"

    Write-Host ""
    Write-Host "    Select which key to update:" -ForegroundColor White
    Write-Host "      1) YouTube Data API Key" -ForegroundColor Cyan
    Write-Host "      2) LLM API Key (Gemini/Groq)" -ForegroundColor Cyan
    Write-Host "      3) Gmail App Password" -ForegroundColor Cyan
    Write-Host "      4) Webshare Proxy Credentials" -ForegroundColor Cyan
    Write-Host "      0) Cancel" -ForegroundColor DarkGray
    Write-Host ""
    $choice = Read-Host "    Choice"

    switch ($choice) {
        "1" {
            $key = Read-Host "    Enter new YouTube API key"
            if ($key) {
                Set-SSMValue -Name "youtube_api_key" -Value $key -Type "SecureString"
                Write-OK "YouTube API key updated"
            }
        }
        "2" {
            $key = Read-Host "    Enter new LLM API key"
            if ($key) {
                Set-SSMValue -Name "llm_api_key" -Value $key -Type "SecureString"
                Write-OK "LLM API key updated"
            }
        }
        "3" {
            $key = Read-Host "    Enter new Gmail App Password"
            if ($key) {
                Set-SSMValue -Name "gmail_app_password" -Value $key -Type "SecureString"
                Write-OK "Gmail App Password updated"
            }
        }
        "4" {
            $user = Read-Host "    Enter Webshare username"
            $pass = Read-Host "    Enter Webshare password"
            if ($user -and $pass) {
                Set-SSMValue -Name "webshare_username" -Value $user
                Set-SSMValue -Name "webshare_password" -Value $pass -Type "SecureString"
                Set-SSMValue -Name "proxy_type" -Value "webshare"
                Write-OK "Webshare credentials updated"
            }
        }
        default { Write-Inf "Cancelled" }
    }
}

# =============================================================================
# Command: info (with health checks)
# =============================================================================

function Test-ApiKeyPlausible {
    param([string]$Value)
    if (-not $Value) { return $false }
    if ($Value -eq "PLACEHOLDER_REPLACE_ME" -or $Value -eq "PLACEHOLDER") { return $false }
    if ($Value.Length -lt 10) { return $false }
    return $true
}

function Test-ConfiguredValue {
    param([string]$Value)
    if (-not $Value) { return $false }
    if ($Value -eq "PLACEHOLDER_REPLACE_ME" -or $Value -eq "PLACEHOLDER") { return $false }
    return $true
}

function Test-EmailPlausible {
    param([string]$Value)
    if (-not $Value) { return $false }
    if ($Value -eq "PLACEHOLDER" -or $Value.Length -lt 5) { return $false }
    return $Value -match ".+@.+\..+"
}

function Invoke-Info {
    Write-Section "System Information" "📊"
    $issues = [System.Collections.Generic.List[string]]::new()

    # --- Channels ---
    $raw = Get-SSMValue -Name "youtube_channels"
    $channels = if ($raw) { @($raw | ConvertFrom-Json) } else { @() }
    Write-Row -Label "Channels" -Value "$($channels.Count) monitored" -Color Cyan
    if ($channels.Count -eq 0) {
        Write-Warn "No YouTube channels configured"
        $issues.Add("No YouTube channels configured — run: .\manage.ps1 channels add <ID>")
    }

    # --- Newsletter schedule ---
    try {
        $rule = aws events describe-rule --name "$Script:LAMBDA_NEWSLETTER-schedule" --output json 2>$null | ConvertFrom-Json
        $sched = $rule.ScheduleExpression
        $state = $rule.State
        $friendlySchedule = switch -Regex ($sched) {
            "rate\(1 day\)"  { "Daily" }
            "rate\(7 days\)" { "Weekly" }
            "cron\(.*1 \* \? \*\)" { "Monthly" }
            default { $sched }
        }
        $schedColor = if ($state -eq "ENABLED") { "Cyan" } else { "Yellow" }
        Write-Row -Label "Newsletter" -Value "$friendlySchedule ($state)" -Color $schedColor
        if ($state -ne "ENABLED") {
            Write-Warn "Newsletter EventBridge rule is DISABLED"
            $issues.Add("Newsletter schedule is DISABLED — newsletter will not be sent automatically")
        }
    } catch {
        Write-Row -Label "Newsletter" -Value "Could not read schedule" -Color Yellow
        $issues.Add("Could not read newsletter EventBridge rule — is infrastructure deployed?")
    }

    # --- Email configuration ---
    $senderEmail = Get-SSMValue -Name "sender_email"
    $destEmail = Get-SSMValue -Name "destination_email"
    $useGmail = Get-SSMValue -Name "use_gmail_smtp"
    $emailMethod = if ($useGmail -eq "true") { "Gmail SMTP" } else { "Amazon SES" }

    Write-Row -Label "Email method" -Value $emailMethod -Color Cyan

    if (Test-EmailPlausible $senderEmail) {
        Write-Row -Label "Sender" -Value "✅ $senderEmail" -Color Green
    } else {
        Write-Row -Label "Sender" -Value "❌ Not set or invalid" -Color Red
        $issues.Add("Sender email not configured — run: .\manage.ps1 email configure")
    }

    if (Test-EmailPlausible $destEmail) {
        Write-Row -Label "Destination" -Value "✅ $destEmail" -Color Green
    } else {
        Write-Row -Label "Destination" -Value "❌ Not set or invalid" -Color Red
        $issues.Add("Destination email not configured — run: .\manage.ps1 email configure")
    }

    # SES verification check (only if using SES)
    if ($useGmail -ne "true") {
        try {
            $identities = aws ses get-identity-verification-attributes `
                --identities $senderEmail $destEmail `
                --output json 2>$null | ConvertFrom-Json

            foreach ($email in @($senderEmail, $destEmail)) {
                if (-not $email) { continue }
                $attr = $identities.VerificationAttributes.$email
                if ($attr -and $attr.VerificationStatus -eq "Success") {
                    Write-Row -Label "  SES: $email" -Value "✅ Verified" -Color Green
                } else {
                    Write-Row -Label "  SES: $email" -Value "❌ Not verified" -Color Red
                    $issues.Add("SES email '$email' is not verified — check your inbox for verification link")
                }
            }
        } catch {
            Write-Warn "Could not check SES verification status"
        }
    } else {
        # Gmail checks
        $gmailSender = Get-SSMValue -Name "gmail_sender"
        $gmailPass = Get-SSMValue -Name "gmail_app_password" -Secure
        if (Test-EmailPlausible $gmailSender) {
            Write-Row -Label "Gmail sender" -Value "✅ $gmailSender" -Color Green
        } else {
            Write-Row -Label "Gmail sender" -Value "❌ Not set" -Color Red
            $issues.Add("Gmail sender not configured — run: .\manage.ps1 email configure")
        }
        if (Test-ApiKeyPlausible $gmailPass) {
            Write-Row -Label "Gmail app password" -Value "✅ Configured" -Color Green
        } else {
            Write-Row -Label "Gmail app password" -Value "❌ Not set" -Color Red
            $issues.Add("Gmail app password not configured — run: .\manage.ps1 apikeys")
        }
    }

    # --- LLM ---
    $llmConfig = Get-SSMValue -Name "llm_config"
    if ($llmConfig) {
        $llm = $llmConfig | ConvertFrom-Json
        Write-Row -Label "LLM provider" -Value "$($llm.provider) / $($llm.model)" -Color Cyan
        Write-Row -Label "Language" -Value ($llm.language ?? "English") -Color White
    }

    # --- API Keys (with plausibility checks) ---
    Write-Host ""
    Write-Host "    🔑 " -NoNewline -ForegroundColor Yellow
    Write-Host "API Keys" -ForegroundColor White

    $ytKey = Get-SSMValue -Name "youtube_api_key" -Secure
    $llmKey = Get-SSMValue -Name "llm_api_key" -Secure

    if (Test-ApiKeyPlausible $ytKey) {
        Write-Row -Label "YouTube API key" -Value "✅ Configured ($($ytKey.Length) chars)" -Color Green
    } else {
        Write-Row -Label "YouTube API key" -Value "❌ Not set or placeholder" -Color Red
        $issues.Add("YouTube API key is missing or invalid — run: .\manage.ps1 apikeys")
    }

    if (Test-ApiKeyPlausible $llmKey) {
        Write-Row -Label "LLM API key" -Value "✅ Configured ($($llmKey.Length) chars)" -Color Green
    } else {
        Write-Row -Label "LLM API key" -Value "❌ Not set or placeholder" -Color Red
        $issues.Add("LLM API key is missing or invalid — run: .\manage.ps1 apikeys")
    }

    # --- Proxy ---
    $proxyType = Get-SSMValue -Name "proxy_type"
    if ($proxyType -eq "webshare") {
        $wsUser = Get-SSMValue -Name "webshare_username"
        $wsPass = Get-SSMValue -Name "webshare_password" -Secure
        if ((Test-ConfiguredValue $wsUser) -and (Test-ConfiguredValue $wsPass)) {
            Write-Row -Label "Proxy" -Value "✅ Webshare ($wsUser)" -Color Green
        } else {
            Write-Row -Label "Proxy" -Value "❌ Webshare selected but credentials missing" -Color Red
            $issues.Add("Webshare proxy selected but credentials not set — run: .\manage.ps1 apikeys")
        }
    } elseif ($proxyType -eq "generic") {
        $genHttp = Get-SSMValue -Name "generic_proxy_http_url" -Secure
        if (Test-ConfiguredValue $genHttp) {
            Write-Row -Label "Proxy" -Value "✅ Generic proxy" -Color Green
        } else {
            Write-Row -Label "Proxy" -Value "❌ Generic proxy selected but URL missing" -Color Red
            $issues.Add("Generic proxy selected but URL not configured")
        }
    } else {
        Write-Row -Label "Proxy" -Value "❌ None (Required)" -Color Red
        $issues.Add("Proxy is not configured — YouTube will block requests. Run: .\manage.ps1 apikeys")
    }

    # --- DynamoDB stats ---
    Write-Host ""
    Write-Host "    📊 " -NoNewline -ForegroundColor Yellow
    Write-Host "DynamoDB Statistics" -ForegroundColor White

    try {
        $scanResult = aws dynamodb scan `
            --table-name $Script:TABLE_NAME `
            --select "COUNT" `
            --output json 2>$null | ConvertFrom-Json
        Write-Row -Label "Total records" -Value $scanResult.Count -Color Cyan

        foreach ($status in @("QUEUED", "PROCESSED", "FAILED", "PERMANENTLY_FAILED")) {
            $countResult = aws dynamodb scan `
                --table-name $Script:TABLE_NAME `
                --filter-expression "#s = :status" `
                --expression-attribute-names '{"#s":"status"}' `
                --expression-attribute-values "{`":status`":{`"S`":`"$status`"}}" `
                --select "COUNT" `
                --output json 2>$null | ConvertFrom-Json
            $color = switch ($status) {
                "PROCESSED" { "Green" }
                "QUEUED" { "Cyan" }
                "FAILED" { "Yellow" }
                "PERMANENTLY_FAILED" { "Red" }
                default { "White" }
            }
            Write-Row -Label "  $status" -Value $countResult.Count -Color $color
        }
    } catch {
        Write-Warn "Could not read DynamoDB stats"
    }

    # --- DLQ ---
    try {
        $queueUrl = (aws sqs get-queue-url --queue-name $Script:DLQ_NAME --output json 2>$null | ConvertFrom-Json).QueueUrl
        $attrs = (aws sqs get-queue-attributes --queue-url $queueUrl --attribute-names ApproximateNumberOfMessages --output json 2>$null | ConvertFrom-Json)
        $dlqCount = [int]$attrs.Attributes.ApproximateNumberOfMessages
        $dlqColor = if ($dlqCount -eq 0) { "Green" } else { "Red" }
        Write-Row -Label "DLQ messages" -Value $dlqCount -Color $dlqColor
        if ($dlqCount -gt 0) {
            $issues.Add("$dlqCount message(s) in DLQ — run: .\manage.ps1 errors")
        }
    } catch {
        Write-Warn "Could not check DLQ"
    }

    # --- Lambda functions ---
    Write-Host ""
    Write-Host "    ⚡ " -NoNewline -ForegroundColor Yellow
    Write-Host "Lambda Functions" -ForegroundColor White

    foreach ($func in @($Script:LAMBDA_POLLER, $Script:LAMBDA_PROCESSOR, $Script:LAMBDA_NEWSLETTER, $Script:LAMBDA_CLEANUP)) {
        try {
            $info = $null
            $json = aws lambda get-function --function-name $func --output json 2>$null
            if (-not $json) { throw "Not deployed" }
            $info = $json | ConvertFrom-Json

            $runtime = $info.Configuration.Runtime
            $memory = $info.Configuration.MemorySize
            $timeout = $info.Configuration.Timeout
            $lastMod = $info.Configuration.LastModified
            Write-Row -Label "  $($func.Split('-')[-1])" -Value "✅ ${runtime} | ${memory}MB | ${timeout}s | $lastMod" -Color Green
        } catch {
            $shortName = $func.Split('-')[-1]
            Write-Row -Label "  $shortName" -Value "❌ Not deployed" -Color Red
            $issues.Add("Lambda '$shortName' is not deployed — run: .\manage.ps1 deploy")
        }
    }

    # --- Health Summary ---
    Write-Host ""
    if ($issues.Count -eq 0) {
        Write-Host "    " -NoNewline
        Write-Host "🟢 Health check: All OK" -ForegroundColor Green
    } else {
        Write-Host "    " -NoNewline
        Write-Host "🔴 Health check: $($issues.Count) issue(s) found" -ForegroundColor Red
        Write-Host ""
        foreach ($issue in $issues) {
            Write-Err $issue
        }
    }
}

# =============================================================================
# Command: cleanup
# =============================================================================

function Invoke-Cleanup {
    switch ($SubCommand) {
        "run" {
            Write-Section "Manual Cleanup" "🧹"
            Write-Inf "Invoking cleanup Lambda..."

            $payload = @{ source = "manual"; "detail-type" = "Manual Cleanup" } | ConvertTo-Json -Compress

            try {
                $tmpFile = [System.IO.Path]::GetTempFileName()
                aws lambda invoke `
                    --function-name $Script:LAMBDA_CLEANUP `
                    --payload $payload `
                    --cli-binary-format raw-in-base64-out `
                    $tmpFile 2>$null | Out-Null

                $result = Get-Content $tmpFile | ConvertFrom-Json
                Remove-Item $tmpFile -Force

                if ($result.statusCode -eq 200) {
                    $body = $result.body | ConvertFrom-Json
                    Write-OK "Cleanup complete"
                    Write-Row -Label "Scanned" -Value $body.stats.scanned -Color Cyan
                    Write-Row -Label "Deleted" -Value $body.stats.deleted -Color Green
                    Write-Row -Label "Errors" -Value $body.stats.errors -Color $(if ($body.stats.errors -gt 0) { "Red" } else { "White" })
                } else {
                    Write-Err "Cleanup failed"
                }
            } catch {
                Write-Err "Could not invoke cleanup Lambda: $_"
            }
        }
        "status" {
            Write-Section "Cleanup Status" "🧹"

            try {
                $scanResult = aws dynamodb scan `
                    --table-name $Script:TABLE_NAME `
                    --filter-expression "#s = :status" `
                    --expression-attribute-names '{"#s":"status"}' `
                    --expression-attribute-values '{":status":{"S":"PERMANENTLY_FAILED"}}' `
                    --select "COUNT" `
                    --output json 2>$null | ConvertFrom-Json

                Write-Row -Label "Permanently failed" -Value "$($scanResult.Count) record(s)" -Color $(if ($scanResult.Count -gt 0) { "Yellow" } else { "Green" })
            } catch {
                Write-Warn "Could not check cleanup status"
            }
        }
        default {
            Write-Err "Usage: .\manage.ps1 cleanup <run|status>"
        }
    }
}

# =============================================================================
# Command: retry
# =============================================================================

function Invoke-Retry {
    Write-Section "Retryable Videos (NO_TRANSCRIPT)" "🔄"

    try {
        $scanResult = aws dynamodb scan `
            --table-name $Script:TABLE_NAME `
            --filter-expression "#s = :status AND failure_reason = :reason" `
            --expression-attribute-names '{"#s":"status"}' `
            --expression-attribute-values '{":status":{"S":"FAILED"},":reason":{"S":"NO_TRANSCRIPT"}}' `
            --projection-expression "video_id, title, retry_count, next_retry_at, first_failed_at" `
            --output json 2>$null | ConvertFrom-Json

        $items = $scanResult.Items
        if ($items.Count -eq 0) {
            Write-OK "No videos awaiting transcript retry"
            return
        }

        Write-TableHeader -Columns @("Video ID", "Retry #", "Next Retry", "First Failed") -Widths @(14, 10, 26, 26)
        foreach ($item in $items) {
            Write-TableRow -Values @(
                ($item.video_id.S ?? "?"),
                ($item.retry_count.N ?? "0"),
                ($item.next_retry_at.S ?? "N/A"),
                ($item.first_failed_at.S ?? "?")
            ) -Widths @(14, 10, 26, 26) -Color Yellow
        }
        Write-Host ""
        Write-Inf "Total: $($items.Count) video(s) awaiting retry"
    } catch {
        Write-Err "Could not query retryable videos: $_"
    }
}

# =============================================================================
# Command: deploy
# =============================================================================

function Invoke-Deploy {
    Write-Section "Deploy Infrastructure" "🚀"
    
    $terraformDir = Join-Path $PSScriptRoot ".." "infra"
    
    if (-not (Test-Path $terraformDir)) {
        Write-Err "Terraform directory not found at $terraformDir"
        return
    }
    
    Push-Location $terraformDir
    
    try {
        Write-Inf "Building Lambda layers..."
        & "$PSScriptRoot\build_layers.ps1"
        if ($LASTEXITCODE -ne 0) {
            throw "Layer build failed with exit code $LASTEXITCODE"
        }

        Write-Inf "Initializing Terraform..."
        terraform init
        
        Write-Inf "Planning deployment..."
        terraform plan -out=tfplan
        
        if (Confirm-Action "Do you want to apply this plan?") {
            Write-Inf "Applying changes..."
            terraform apply "tfplan"
            Write-OK "Deployment complete!"
            
            # Reminder to configure things
            Write-Host ""
            Write-Inf "Remember to configure your application if this is a fresh deploy:"
            Write-Host "  .\manage.ps1 apikeys" -ForegroundColor Cyan
            Write-Host "  .\manage.ps1 email configure" -ForegroundColor Cyan
            Write-Host "  .\manage.ps1 channels add <ID>" -ForegroundColor Cyan
        } else {
            Write-Inf "Deployment cancelled."
        }
    } catch {
        Write-Err "Terraform failed: $_"
    } finally {
        if (Test-Path "tfplan") { Remove-Item "tfplan" }
        Pop-Location
    }
}

# =============================================================================
# Command: process (video pipeline — merged from vidscribe.ps1)
# =============================================================================

function Invoke-Process {
    if (-not $SubCommand) {
        Write-Err "Usage: .\manage.ps1 process <URL1> [URL2...]"
        Write-Inf "Options: -SkipNewsletter (process without sending newsletter)"
        return
    }

    Write-Section "Video Processing Pipeline" "🚀"

    # Collect all URLs from SubCommand and Argument
    $urls = @($SubCommand)
    if ($Argument) { $urls += $Argument }

    $videoIds = $urls | ForEach-Object { Extract-VideoId $_ }
    Write-Inf "Video IDs: $($videoIds -join ', ')"

    # 1. Check SQS queue
    Write-Host ""
    Write-Host "    🔍 " -NoNewline -ForegroundColor Yellow
    Write-Host "Checking AWS Resources" -ForegroundColor White

    try {
        $queueUrl = (aws sqs get-queue-url --queue-name $Script:QUEUE_NAME --output json 2>$null | ConvertFrom-Json).QueueUrl
        if (-not $queueUrl) { throw "Queue not found" }
        Write-OK "Queue: $Script:QUEUE_NAME"
    } catch {
        Write-Err "SQS queue not found. Is the infrastructure deployed?"
        Write-Inf "Run: .\manage.ps1 deploy"
        return
    }

    $startTime = [int64]((Get-Date).ToUniversalTime() - (Get-Date "1970-01-01").ToUniversalTime()).TotalMilliseconds

    # 2. Inject videos
    Write-Host ""
    Write-Host "    💉 " -NoNewline -ForegroundColor Yellow
    Write-Host "Injecting $($videoIds.Count) video(s) into queue" -ForegroundColor White

    foreach ($vid in $videoIds) {
        $body = @{
            video_id      = $vid
            title         = "Manual: $vid"
            channel_id    = "MANUAL"
            channel_title = "Manual Trigger"
            published_at  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        } | ConvertTo-Json -Compress

        try {
            aws sqs send-message --queue-url $queueUrl --message-body $body --no-cli-pager 2>$null | Out-Null
            Write-Inf "→ $vid"
        } catch {
            Write-Err "Failed to inject $vid"
        }
    }
    Write-OK "All videos queued"

    # 3. Monitor processing
    $waitTimeout = 300
    Write-Host ""
    Write-Host "    ⏳ " -NoNewline -ForegroundColor Yellow
    Write-Host "Waiting for processing (max ${waitTimeout}s)" -ForegroundColor White

    $pending = [System.Collections.Generic.HashSet[string]]::new([string[]]$videoIds)
    $failed = [System.Collections.Generic.HashSet[string]]::new()
    $elapsed = 0
    $pollInterval = 5
    $processorLogGroup = $Script:LOG_GROUPS["processor"]

    while ($pending.Count -gt 0 -and $elapsed -lt $waitTimeout) {
        Start-Sleep -Seconds $pollInterval
        $elapsed += $pollInterval

        try {
            $logs = aws logs filter-log-events `
                --log-group-name $processorLogGroup `
                --start-time $startTime `
                --output json 2>$null | ConvertFrom-Json

            if ($logs -and $logs.events) {
                foreach ($event in $logs.events) {
                    $msg = $event.message
                    if ($msg -match "Successfully processed video: (.+)") {
                        $processedId = $Matches[1].Trim()
                        if ($pending.Contains($processedId)) {
                            $pending.Remove($processedId) | Out-Null
                            Write-OK "Processed: $processedId"
                        }
                    }
                    if ($msg -match "Error|Failed|Exception" -and $msg -match "video.*?([a-zA-Z0-9_-]{11})") {
                        $failedId = $Matches[1]
                        if ($pending.Contains($failedId)) {
                            $pending.Remove($failedId) | Out-Null
                            $failed.Add($failedId) | Out-Null
                            Write-VideoFailureDiagnostics -VideoId $failedId -StartTime $startTime
                        }
                    }
                }
            }
        } catch { }

        # Fallback to DynamoDB status to avoid false 300s waits when processor
        # completes with non-success logs (e.g. FAILED/PERMANENTLY_FAILED).
        foreach ($vid in @($pending)) {
            $status = Get-VideoProcessingStatus -VideoId $vid
            if ($status -eq "PROCESSED") {
                $pending.Remove($vid) | Out-Null
                Write-OK "Processed: $vid"
            } elseif ($status -eq "FAILED" -or $status -eq "PERMANENTLY_FAILED") {
                $pending.Remove($vid) | Out-Null
                $failed.Add($vid) | Out-Null
                Write-VideoFailureDiagnostics -VideoId $vid -StartTime $startTime -Status $status
            }
        }

        Write-Host "." -NoNewline -ForegroundColor DarkGray
    }

    Write-Host ""
    if ($pending.Count -gt 0) {
        Write-Warn "Timeout! Still pending: $($pending -join ', ')"
        Write-Inf "Videos may still be processing. Check: .\manage.ps1 logs processor"
    } elseif ($failed.Count -gt 0) {
        Write-Warn "Completed with failures: $($failed -join ', ')"
    } else {
        Write-OK "All videos processed!"
    }

    # 4. Send newsletter (unless skipped via Argument containing 'skip')
    # Note: use manage.ps1 newsletter test to send manually if skipped
    Write-Host ""
    Write-Host "    📧 " -NoNewline -ForegroundColor Yellow
    Write-Host "Sending Newsletter" -ForegroundColor White

    try {
        $tmpFile = [System.IO.Path]::GetTempFileName()
        aws lambda invoke `
            --function-name $Script:LAMBDA_NEWSLETTER `
            --cli-binary-format raw-in-base64-out `
            $tmpFile `
            --no-cli-pager 2>$null | Out-Null

        $response = Get-Content $tmpFile -Raw | ConvertFrom-Json
        Remove-Item $tmpFile -Force

        if ($response.statusCode -eq 200) {
            Write-OK "Newsletter sent!"
            $body = $response.body | ConvertFrom-Json
            Write-Row -Label "Summaries" -Value $body.summaries_count -Color Cyan
        } elseif ($response.errorMessage) {
            Write-Err "Newsletter error: $($response.errorMessage)"
        } else {
            Write-Warn "Newsletter response: $($response | ConvertTo-Json -Compress)"
        }
    } catch {
        Write-Err "Could not invoke newsletter Lambda: $_"
    }

    Write-Host ""
    Write-OK "WORKFLOW COMPLETE"
}

# =============================================================================
# Command: help
# =============================================================================

function Invoke-Help {
    Write-Banner

    Write-Host "  USAGE" -ForegroundColor White
    Write-Host "    .\manage.ps1 <command> [subcommand] [options]" -ForegroundColor Gray
    Write-Host ""

    Write-Host "  COMMANDS" -ForegroundColor White
    Write-Host ""
    $cmds = @(
        @("deploy", "Deploy infrastructure changes (Terraform)"),
        @("channels list", "List monitored channels with names"),
        @("channels add <ID>", "Add a YouTube channel by ID"),
        @("channels remove <ID>", "Remove a channel by ID"),
        @("channels clear", "Remove all monitored channels"),
        @("process <URL> [URL2...]", "Process video(s): queue + monitor + newsletter"),
        @("newsletter frequency <f>", "Set frequency: daily, weekly, monthly"),
        @("newsletter test", "Invoke newsletter Lambda (send with existing data)"),
        @("newsletter test-insert", "Insert test summary + send newsletter"),
        @("errors", "Show failed videos, DLQ, Lambda errors"),
        @("logs <function>", "Tail CloudWatch logs (poller/processor/...)"),
        @("apikeys", "Interactive API key update wizard"),
        @("info", "System status + health check dashboard"),
        @("cleanup run", "Manually trigger DynamoDB cleanup"),
        @("cleanup status", "Show permanently failed record count"),
        @("retry list", "Show videos awaiting transcript retry"),
        @("email method <ses|gmail>", "Switch email provider"),
        @("email configure", "Configure email settings"),
        @("help", "Show this help message")
    )
    foreach ($cmd in $cmds) {
        Write-Host "    $($cmd[0].PadRight(30))" -NoNewline -ForegroundColor Cyan
        Write-Host $cmd[1] -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host "  OPTIONS" -ForegroundColor White
    Write-Host "    -Lines <N>           Number of log lines to show (default: 50)" -ForegroundColor Gray
    Write-Host "    -DaysBack <N>        Days to look back for errors (default: 7)" -ForegroundColor Gray
    Write-Host "    -ProjectName <name>  Project name prefix (default: vidscribe)" -ForegroundColor Gray
    Write-Host "    -Stage <stage>       Deployment stage (default: prod)" -ForegroundColor Gray
    Write-Host ""

    Write-Host "  EXAMPLES" -ForegroundColor White
    Write-Host '    .\manage.ps1 channels add "UCBcRF18a7Qf58cCRy5xuWwQ"' -ForegroundColor DarkGray
    Write-Host '    .\manage.ps1 process "https://youtube.com/watch?v=abc123"' -ForegroundColor DarkGray
    Write-Host '    .\manage.ps1 newsletter frequency weekly' -ForegroundColor DarkGray
    Write-Host '    .\manage.ps1 newsletter test-insert' -ForegroundColor DarkGray
    Write-Host '    .\manage.ps1 logs processor -Lines 100' -ForegroundColor DarkGray
    Write-Host '    .\manage.ps1 info' -ForegroundColor DarkGray
    Write-Host ""
}

# =============================================================================
# Main Router
# =============================================================================

Write-Banner

switch ($Command) {
    "deploy"     { Invoke-Deploy }
    "channels"   { Invoke-Channels }
    "process"    { Invoke-Process }
    "newsletter" { Invoke-Newsletter }
    "errors"     { Invoke-Errors }
    "logs"       { Invoke-Logs }
    "apikeys"    { Invoke-ApiKeys }
    "info"       { Invoke-Info }
    "cleanup"    { Invoke-Cleanup }
    "retry"      { Invoke-Retry }
    "email"      { Invoke-Email }
    "help"       { Invoke-Help }
    ""           { Invoke-Help }
    default      {
        Write-Err "Unknown command: $Command"
        Write-Host ""
        Write-Inf "Run '.\manage.ps1 help' for usage information"
    }
}

Write-Host ""
