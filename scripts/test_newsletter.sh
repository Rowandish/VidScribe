#!/bin/bash
# =============================================================================
# VidScribe - Test Newsletter Script
# =============================================================================
# This script inserts a test summary into DynamoDB and triggers the newsletter
# Lambda to send a test email.
# =============================================================================

set -e

TABLE_NAME="${1:-vidscribe-videos}"
FUNCTION_NAME="${2:-vidscribe-newsletter}"

echo "🧪 VidScribe Newsletter Test"
echo "================================"
echo ""

# Generate test data
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TTL=$(date -d "+30 days" +%s)
VIDEO_ID="test-$RANDOM"

echo "📝 Inserting test summary into DynamoDB..."
echo "   Table: $TABLE_NAME"
echo "   Video ID: $VIDEO_ID"

# Insert test summary
aws dynamodb put-item \
    --table-name "$TABLE_NAME" \
    --item "{
        \"pk\": {\"S\": \"SUMMARY#$VIDEO_ID\"},
        \"sk\": {\"S\": \"DATA\"},
        \"gsi1pk\": {\"S\": \"SUMMARY\"},
        \"gsi1sk\": {\"S\": \"$NOW\"},
        \"video_id\": {\"S\": \"$VIDEO_ID\"},
        \"title\": {\"S\": \"🎬 Test Video - VidScribe Newsletter Test\"},
        \"channel_title\": {\"S\": \"VidScribe Test Channel\"},
        \"summary\": {\"S\": \"Questo è un video di test per verificare che il sistema di newsletter VidScribe funzioni correttamente.\n\nIl video include i seguenti argomenti:\n\n**Funzionalità testate:**\n- Formattazione HTML del contenuto\n- Link corretti al video YouTube\n- Data di pubblicazione formattata\n- Stile responsive dell'email\n\n**Risultato atteso:**\nSe ricevi questa email con una formattazione corretta e tutti i link funzionanti, il sistema VidScribe è operativo! 🎉\n\n**Prossimi passi:**\n1. Verifica che l'email sia ben formattata\n2. Clicca sul link del video per testare la navigazione\n3. Controlla che la data sia corretta\n4. Se tutto funziona, il sistema è pronto per l'uso in produzione!\"},
        \"published_at\": {\"S\": \"$NOW\"},
        \"summarized_at\": {\"S\": \"$NOW\"},
        \"ttl\": {\"N\": \"$TTL\"}
    }" \
    --no-cli-pager

echo "✅ Test summary inserted successfully!"
echo ""

echo "📧 Invoking Newsletter Lambda..."
echo "   Function: $FUNCTION_NAME"

aws lambda invoke \
    --function-name "$FUNCTION_NAME" \
    --payload '{}' \
    --cli-binary-format raw-in-base64-out \
    response.json \
    --no-cli-pager

echo "✅ Newsletter Lambda invoked successfully!"
echo ""

echo "📄 Lambda Response:"
cat response.json | jq '.'
echo ""

# Clean up response file
rm -f response.json

echo "🎉 Test completed!"
echo ""
echo "📬 Check your email inbox for the newsletter."
echo "   If you don't see it, check:"
echo "   - Spam/Junk folder"
echo "   - SES email verification status"
echo "   - CloudWatch logs: /aws/lambda/$FUNCTION_NAME"
echo ""
echo "🧹 To clean up the test data, run:"
echo "   aws dynamodb delete-item --table-name $TABLE_NAME --key '{\"pk\":{\"S\":\"SUMMARY#$VIDEO_ID\"},\"sk\":{\"S\":\"DATA\"}}'"
