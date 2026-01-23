#!/usr/bin/env pwsh
# =============================================================================
# VidScribe - Manual Video Injection Script
# =============================================================================
# Injects a specific YouTube video ID into the SQS queue to trigger
# processing (transcript download and summarization).
# =============================================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$VideoId,

    [string]$QueueName = "vidscribe-prod-video-queue"
)

Write-Host "🚀 VidScribe Manual Video Injection" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host ""

# 1. Get Queue URL
Write-Host "🔍 Locating SQS queue: $QueueName..." -ForegroundColor Yellow
try {
    $QueueUrl = aws sqs get-queue-url --queue-name $QueueName --query 'QueueUrl' --output text 2>$null
    if ($null -eq $QueueUrl -or $QueueUrl -eq "") {
        throw "Could not find queue URL for $QueueName"
    }
    Write-Host "✅ Found: $QueueUrl" -ForegroundColor Green
} catch {
    Write-Host "❌ Error: Could not find the SQS queue. Make sure you are logged into AWS and the infra is deployed." -ForegroundColor Red
    exit 1
}

# 2. Prepare Message Body
# We use a real video ID but generic metadata for testing
$now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$body = @{
    video_id      = $VideoId
    title         = "Manual Test: $VideoId"
    channel_id    = "MANUAL_TEST"
    channel_title = "Manual Trigger"
    published_at  = $now
} | ConvertTo-Json -Compress

Write-Host "📝 Preparing message for Video ID: $VideoId..." -ForegroundColor Yellow

# 3. Send Message
try {
    aws sqs send-message --queue-url $QueueUrl --message-body $body --no-cli-pager
    Write-Host ""
    Write-Host "🎯 SUCCESS! Message injected into SQS." -ForegroundColor Green
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "💡 What's next?" -ForegroundColor Gray
    Write-Host "1. Check the Processor Lambda logs to see the summarization in progress:" -ForegroundColor Gray
    Write-Host "   aws logs tail /aws/lambda/vidscribe-prod-processor --follow" -ForegroundColor White
    Write-Host ""
    Write-Host "2. Once processed, trigger the newsletter to receive the result:" -ForegroundColor Gray
    Write-Host "   aws lambda invoke --function-name vidscribe-prod-newsletter output.json" -ForegroundColor White
    Write-Host ""
} catch {
    Write-Host "❌ Failed to send message to SQS: $_" -ForegroundColor Red
    exit 1
}
