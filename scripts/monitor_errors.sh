#!/bin/bash
# =============================================================================
# 🏥 VidScribe - Healthy Monitor Script (Bash)
# =============================================================================

DAYS_BACK=7
PROJECT_NAME="vidscribe"
STAGE="prod"
PREFIX="$PROJECT_NAME-$STAGE"

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
RESET='\033[0m'
GRAY='\033[0;90m'

echo -e "${MAGENTA}"
echo "   __  __             _ _             "
echo "  |  \/  |           (_) |            "
echo "  | \  / | ___  _ __  _| |_ ___  _ __ "
echo "  | |\/| |/ _ \| '_ \| | __/ _ \| '__|"
echo "  | |  | | (_) | | | | | || (_) | |   "
echo "  |_|  |_|\___/|_| |_|_|\__\___/|_|   "
echo -e "${RESET}"
echo -e "${MAGENTA}🏥 SYSTEM HEALTH CHECK (Last $DAYS_BACK days)${RESET}"

# -----------------------------------------------------------------------------
# 1. DynamoDB Failures
# -----------------------------------------------------------------------------
echo -e "\n${CYAN}1. DynamoDB Errors (Status = FAILED)${RESET}"
echo "----------------------------------------"

TABLE_NAME="$PREFIX-videos"

# Scan using query to output tab-separated text
FAILED_ITEMS=$(aws dynamodb scan \
    --table-name "$TABLE_NAME" \
    --filter-expression "#s = :f" \
    --expression-attribute-names '{"#s": "status"}' \
    --expression-attribute-values '{":f": {"S": "FAILED"}}' \
    --projection-expression "video_id, title, failure_reason, failed_at" \
    --query 'Items[*].[failed_at.S, title.S, video_id.S, failure_reason.S]' \
    --output text 2>/dev/null)

if [ -n "$FAILED_ITEMS" ] && [ "$FAILED_ITEMS" != "None" ]; then
    NUM_FAILED=$(echo "$FAILED_ITEMS" | wc -l)
    echo -e "${RED}Found $NUM_FAILED failed videos:${RESET}"
    
    # Read line by line
    while IFS=$'\t' read -r FAILED_AT TITLE VID_ID REASON; do
        echo -e "   - [${FAILED_AT}] ${YELLOW}${TITLE}${RESET} (${VID_ID})"
        echo -e "     ${GRAY}Reason: ${REASON}${RESET}"
    done <<< "$FAILED_ITEMS"
else
    echo -e "${GREEN}No failed videos found.${RESET}"
fi

# -----------------------------------------------------------------------------
# 2. SQS Dead Letter Queue
# -----------------------------------------------------------------------------
echo -e "\n${CYAN}2. SQS Dead Letter Queue (DLQ)${RESET}"
echo "----------------------------------------"

DLQ_NAME="$PREFIX-video-dlq"
DLQ_URL=$(aws sqs get-queue-url --queue-name "$DLQ_NAME" --query 'QueueUrl' --output text 2>/dev/null)

if [ -n "$DLQ_URL" ]; then
    MSG_COUNT=$(aws sqs get-queue-attributes --queue-url "$DLQ_URL" --attribute-names ApproximateNumberOfMessages --query 'Attributes.ApproximateNumberOfMessages' --output text)
    
    if [ "$MSG_COUNT" -gt 0 ]; then
        echo -e "${RED}⚠️  DLQ is NOT empty!${RESET}"
        echo -e "${YELLOW}   Pending Messages: $MSG_COUNT${RESET}"
        echo -e "${GRAY}   Run: aws sqs receive-message --queue-url $DLQ_URL --max-number-of-messages 10${RESET}"
    else
        echo -e "${GREEN}DLQ is empty.${RESET}"
    fi
else
    echo -e "${RED}DLQ '$DLQ_NAME' not found.${RESET}"
fi

# -----------------------------------------------------------------------------
# 3. Lambda Logs
# -----------------------------------------------------------------------------
echo -e "\n${CYAN}3. Lambda Error Logs${RESET}"
echo "----------------------------------------"

# Calculate timestamp logic (same as previous script)
if [[ "$OSTYPE" == "darwin"* ]]; then
    # MacOS date
    NOW_EPOCH=$(date +%s)
else
    # Linux date
    NOW_EPOCH=$(date +%s)
fi
# Subtract days in seconds (86400 * days)
START_EPOCH=$(( NOW_EPOCH - (DAYS_BACK * 86400) ))
START_MS=$(( START_EPOCH * 1000 ))

FUNCTIONS=("poller" "processor" "newsletter")

for FUNC in "${FUNCTIONS[@]}"; do
    LOG_GROUP="/aws/lambda/$PREFIX-$FUNC"
    echo -e "\nChecking $LOG_GROUP..."
    
    LOGS=$(aws logs filter-log-events \
        --log-group-name "$LOG_GROUP" \
        --start-time "$START_MS" \
        --filter-pattern '"?ERROR" "?Exception" "?Fail"' \
        --limit 5 \
        --query 'events[*].[timestamp, message]' \
        --output text 2>/dev/null)
        
    if [ -n "$LOGS" ] && [ "$LOGS" != "None" ]; then
        echo -e "${RED}Found recent errors:${RESET}"
        while IFS=$'\t' read -r TS MSG; do
            # Format timestamp human readable? requires date tricks. 
            # Just showing raw text message for simplicity & speed
            MSG_TRUNC="${MSG:0:150}"
            if [ ${#MSG} -gt 150 ]; then MSG_TRUNC="${MSG_TRUNC}..."; fi
            echo -e "   - ${YELLOW}${MSG_TRUNC}${RESET}"
        done <<< "$LOGS"
    else
        echo -e "${GREEN}No obvious errors found.${RESET}"
    fi
done

echo -e "\n${MAGENTA}🏥 Check Complete${RESET}\n"
