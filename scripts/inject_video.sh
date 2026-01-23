#!/bin/bash
# =============================================================================
# VidScribe - Manual Video Injection Script (Bash)
# =============================================================================
# Injects a specific YouTube video ID into the SQS queue to trigger
# processing (transcript download and summarization).
# =============================================================================

set -e

# Colors for output
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

VIDEO_ID=$1
QUEUE_NAME="${2:-vidscribe-prod-video-queue}"

if [ -z "$VIDEO_ID" ]; then
    echo -e "${RED}Error:${NC} Video ID is required."
    echo "Usage: ./scripts/inject_video.sh <VIDEO_ID> [QUEUE_NAME]"
    exit 1
fi

echo -e "${CYAN}🚀 VidScribe Manual Video Injection${NC}"
echo -e "${CYAN}======================================${NC}"
echo ""

# 1. Get Queue URL
echo -e "${YELLOW}🔍 Locating SQS queue: $QUEUE_NAME...${NC}"
QUEUE_URL=$(aws sqs get-queue-url --queue-name "$QUEUE_NAME" --query 'QueueUrl' --output text 2>/dev/null)

if [ -z "$QUEUE_URL" ]; then
    echo -e "${RED}❌ Error:${NC} Could not find SQS queue URL for $QUEUE_NAME."
    echo "Make sure you are logged into AWS and the infrastructure is deployed."
    exit 1
fi
echo -e "${GREEN}✅ Found: $QUEUE_URL${NC}"

# 2. Prepare Message Body
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
MESSAGE_BODY=$(cat <<EOF
{
    "video_id": "$VIDEO_ID",
    "title": "Manual Test: $VIDEO_ID",
    "channel_id": "MANUAL_TEST",
    "channel_title": "Manual Trigger",
    "published_at": "$NOW"
}
EOF
)

echo -e "${YELLOW}📝 Preparing message for Video ID: $VIDEO_ID...${NC}"

# 3. Send Message
aws sqs send-message --queue-url "$QUEUE_URL" --message-body "$MESSAGE_BODY" --no-cli-pager

echo ""
echo -e "${GREEN}🎯 SUCCESS! Message injected into SQS.${NC}"
echo -e "${CYAN}======================================${NC}"
echo ""
echo -e "${GRAY}💡 What's next?${NC}"
echo -e "1. Check the Processor Lambda logs to see the summarization in progress:"
echo -e "   ${GREEN}aws logs tail /aws/lambda/vidscribe-prod-processor --follow${NC}"
echo ""
echo -e "2. Once processed, trigger the newsletter to receive the result:"
echo -e "   ${GREEN}aws lambda invoke --function-name vidscribe-prod-newsletter output.json${NC}"
echo ""
