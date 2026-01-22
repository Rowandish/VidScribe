#!/usr/bin/env pwsh
# =============================================================================
# VidScribe - Test Newsletter Script
# =============================================================================
# This script inserts a test summary into DynamoDB and triggers the newsletter
# Lambda to send a test email.
# =============================================================================

param(
    [string]$TableName = "vidscribe-prod-videos",
    [string]$FunctionName = "vidscribe-prod-newsletter"
)

Write-Host "🧪 VidScribe Newsletter Test" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan
Write-Host ""

# Generate test data
$now = Get-Date -Format "yyyy-MM-ddTHH:mm:ssK"
$ttl = [int](Get-Date).AddDays(30).ToUniversalTime().Subtract([datetime]'1970-01-01').TotalSeconds
$videoId = "test-$(Get-Random -Minimum 1000 -Maximum 9999)"

Write-Host "📝 Inserting test summary into DynamoDB..." -ForegroundColor Yellow
Write-Host "   Table: $TableName" -ForegroundColor Gray
Write-Host "   Video ID: $videoId" -ForegroundColor Gray

# Insert test summary
$item = @{
    pk = @{ S = "SUMMARY#$videoId" }
    sk = @{ S = "DATA" }
    gsi1pk = @{ S = "SUMMARY" }
    gsi1sk = @{ S = $now }
    video_id = @{ S = $videoId }
    title = @{ S = "🎬 Test Video - VidScribe Newsletter Test" }
    channel_title = @{ S = "VidScribe Test Channel" }
    summary = @{ S = @"
Questo è un video di test per verificare che il sistema di newsletter VidScribe funzioni correttamente.

Il video include i seguenti argomenti:

**Funzionalità testate:**
- Formattazione HTML del contenuto
- Link corretti al video YouTube
- Data di pubblicazione formattata
- Stile responsive dell'email

**Risultato atteso:**
Se ricevi questa email con una formattazione corretta e tutti i link funzionanti, il sistema VidScribe è operativo! 🎉

**Prossimi passi:**
1. Verifica che l'email sia ben formattata
2. Clicca sul link del video per testare la navigazione
3. Controlla che la data sia corretta
4. Se tutto funziona, il sistema è pronto per l'uso in produzione!
"@ }
    published_at = @{ S = $now }
    summarized_at = @{ S = $now }
    ttl = @{ N = $ttl.ToString() }
}

try {
    aws dynamodb put-item `
        --table-name $TableName `
        --item ($item | ConvertTo-Json -Depth 10 -Compress) `
        --no-cli-pager
    
    Write-Host "✅ Test summary inserted successfully!" -ForegroundColor Green
    Write-Host ""
} catch {
    Write-Host "❌ Error inserting test summary: $_" -ForegroundColor Red
    exit 1
}

Write-Host "📧 Invoking Newsletter Lambda..." -ForegroundColor Yellow
Write-Host "   Function: $FunctionName" -ForegroundColor Gray

try {
    $response = aws lambda invoke `
        --function-name $FunctionName `
        --payload '{}' `
        --cli-binary-format raw-in-base64-out `
        response.json `
        --no-cli-pager
    
    Write-Host "✅ Newsletter Lambda invoked successfully!" -ForegroundColor Green
    Write-Host ""
    
    # Display response
    Write-Host "📄 Lambda Response:" -ForegroundColor Cyan
    Get-Content response.json | ConvertFrom-Json | ConvertTo-Json -Depth 10
    Write-Host ""
    
    # Clean up response file
    Remove-Item response.json -ErrorAction SilentlyContinue
    
} catch {
    Write-Host "❌ Error invoking Newsletter Lambda: $_" -ForegroundColor Red
    exit 1
}

Write-Host "🎉 Test completed!" -ForegroundColor Green
Write-Host ""
Write-Host "📬 Check your email inbox for the newsletter." -ForegroundColor Yellow
Write-Host "   If you don't see it, check:" -ForegroundColor Gray
Write-Host "   - Spam/Junk folder" -ForegroundColor Gray
Write-Host "   - SES email verification status" -ForegroundColor Gray
Write-Host "   - CloudWatch logs: /aws/lambda/$FunctionName" -ForegroundColor Gray
Write-Host ""
Write-Host "🧹 To clean up the test data, run:" -ForegroundColor Cyan
Write-Host "   aws dynamodb delete-item --table-name $TableName --key '{""pk"":{""S"":""SUMMARY#$videoId""},""sk"":{""S"":""DATA""}}'" -ForegroundColor Gray
