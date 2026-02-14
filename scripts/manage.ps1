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
    Write-Host "                            ║" -ForegroundColor DarkCyan
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
# Command: newsletter
# =============================================================================

function Invoke-Newsletter {
    switch ($SubCommand) {
        "frequency" { Invoke-NewsletterFrequency }
        "test"      { Invoke-NewsletterTest }
        default     {
            Write-Err "Usage: .\manage.ps1 newsletter <frequency|test> [value]"
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

    if ($Argument) {
        # Process a video first, then send newsletter
        Write-Inf "Processing video and sending test newsletter..."
        & "$PSScriptRoot\vidscribe.ps1" -Urls $Argument -TestNewsletter
    } else {
        Write-Inf "Invoking newsletter Lambda..."
        $payload = @{ source = "manual-test"; "detail-type" = "Manual Test" } | ConvertTo-Json -Compress
        $result = aws lambda invoke `
            --function-name $Script:LAMBDA_NEWSLETTER `
            --payload $payload `
            --cli-binary-format raw-in-base64-out `
            --output json `
            /dev/null 2>$null | ConvertFrom-Json

        if ($result.StatusCode -eq 200) {
            Write-OK "Test newsletter sent successfully"
        } else {
            Write-Err "Newsletter invocation failed (status: $($result.StatusCode))"
        }
    }
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
                Write-OK "Webshare credentials updated"
            }
        }
        default { Write-Inf "Cancelled" }
    }
}

# =============================================================================
# Command: info
# =============================================================================

function Invoke-Info {
    Write-Section "System Information" "📊"

    # Channels
    $raw = Get-SSMValue -Name "youtube_channels"
    $channels = if ($raw) { @($raw | ConvertFrom-Json) } else { @() }
    Write-Row -Label "Channels" -Value "$($channels.Count) monitored" -Color Cyan

    # Newsletter schedule
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
        Write-Row -Label "Newsletter" -Value "$friendlySchedule ($state)" -Color Cyan
    } catch {
        Write-Row -Label "Newsletter" -Value "Could not read schedule" -Color Yellow
    }

    # Email configuration
    $senderEmail = Get-SSMValue -Name "sender_email"
    $destEmail = Get-SSMValue -Name "destination_email"
    $useGmail = Get-SSMValue -Name "use_gmail_smtp"
    $emailMethod = if ($useGmail -eq "true") { "Gmail SMTP" } else { "Amazon SES" }

    Write-Row -Label "Email method" -Value $emailMethod -Color Cyan
    Write-Row -Label "Sender" -Value ($senderEmail ?? "Not set") -Color White
    Write-Row -Label "Destination" -Value ($destEmail ?? "Not set") -Color White

    # LLM
    $llmConfig = Get-SSMValue -Name "llm_config"
    if ($llmConfig) {
        $llm = $llmConfig | ConvertFrom-Json
        Write-Row -Label "LLM provider" -Value "$($llm.provider) / $($llm.model)" -Color Cyan
        Write-Row -Label "Language" -Value ($llm.language ?? "English") -Color White
    }

    # API Keys status
    $ytKey = Get-SSMValue -Name "youtube_api_key" -Secure
    $llmKey = Get-SSMValue -Name "llm_api_key" -Secure
    $ytStatus = if ($ytKey -and $ytKey -ne "PLACEHOLDER_REPLACE_ME") { "✅ Configured" } else { "❌ Not set" }
    $llmStatus = if ($llmKey -and $llmKey -ne "PLACEHOLDER_REPLACE_ME") { "✅ Configured" } else { "❌ Not set" }
    Write-Row -Label "YouTube API key" -Value $ytStatus
    Write-Row -Label "LLM API key" -Value $llmStatus

    # Proxy
    $wsUser = Get-SSMValue -Name "webshare_username"
    $proxyStatus = if ($wsUser -and $wsUser -ne "PLACEHOLDER") { "✅ Webshare ($wsUser)" } else { "None" }
    Write-Row -Label "Proxy" -Value $proxyStatus

    # DynamoDB stats
    Write-Host ""
    Write-Host "    📊 " -NoNewline -ForegroundColor Yellow
    Write-Host "DynamoDB Statistics" -ForegroundColor White

    try {
        $scanResult = aws dynamodb scan `
            --table-name $Script:TABLE_NAME `
            --select "COUNT" `
            --output json 2>$null | ConvertFrom-Json
        Write-Row -Label "Total records" -Value $scanResult.Count -Color Cyan

        # Count by status
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

    # DLQ
    try {
        $queueUrl = (aws sqs get-queue-url --queue-name $Script:DLQ_NAME --output json 2>$null | ConvertFrom-Json).QueueUrl
        $attrs = (aws sqs get-queue-attributes --queue-url $queueUrl --attribute-names ApproximateNumberOfMessages --output json 2>$null | ConvertFrom-Json)
        $dlqCount = [int]$attrs.Attributes.ApproximateNumberOfMessages
        $dlqColor = if ($dlqCount -eq 0) { "Green" } else { "Red" }
        Write-Row -Label "DLQ messages" -Value $dlqCount -Color $dlqColor
    } catch {
        Write-Warn "Could not check DLQ"
    }

    # Lambda functions status
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
            Write-Row -Label "  $($func.Split('-')[-1])" -Value "❌ Not deployed" -Color Red
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
        @("channels list", "List monitored channels with names"),
        @("channels add <ID>", "Add a YouTube channel by ID"),
        @("channels remove <ID>", "Remove a channel by ID"),
        @("channels clear", "Remove all monitored channels"),
        @("newsletter frequency <f>", "Set frequency: daily, weekly, monthly"),
        @("newsletter test [URL]", "Send a test newsletter"),
        @("errors", "Show failed videos, DLQ, Lambda errors"),
        @("logs <function>", "Tail CloudWatch logs (poller/processor/...)"),
        @("apikeys update", "Interactive API key update wizard"),
        @("info", "Full system status dashboard"),
        @("cleanup run", "Manually trigger DynamoDB cleanup"),
        @("cleanup status", "Show permanently failed record count"),
        @("retry list", "Show videos awaiting transcript retry"),
        @("help", "Show this help message")
    )
    foreach ($cmd in $cmds) {
        Write-Host "    $($cmd[0].PadRight(28))" -NoNewline -ForegroundColor Cyan
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
    Write-Host '    .\manage.ps1 newsletter frequency weekly' -ForegroundColor DarkGray
    Write-Host '    .\manage.ps1 logs processor -Lines 100' -ForegroundColor DarkGray
    Write-Host '    .\manage.ps1 errors -DaysBack 14' -ForegroundColor DarkGray
    Write-Host ""
}

# =============================================================================
# Main Router
# =============================================================================

Write-Banner

switch ($Command) {
    "channels"   { Invoke-Channels }
    "newsletter" { Invoke-Newsletter }
    "errors"     { Invoke-Errors }
    "logs"       { Invoke-Logs }
    "apikeys"    { Invoke-ApiKeys }
    "info"       { Invoke-Info }
    "cleanup"    { Invoke-Cleanup }
    "retry"      { Invoke-Retry }
    "help"       { Invoke-Help }
    ""           { Invoke-Help }
    default      {
        Write-Err "Unknown command: $Command"
        Write-Host ""
        Write-Inf "Run '.\manage.ps1 help' for usage information"
    }
}

Write-Host ""
