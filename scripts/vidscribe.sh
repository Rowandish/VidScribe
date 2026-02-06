#!/usr/bin/env bash
# =============================================================================
# 🚀 VidScribe - Unified Workflow Script
# =============================================================================
# Process YouTube videos from URL to Newsletter in one command.
#
# Usage:
#   ./vidscribe.sh "https://youtube.com/watch?v=abc123"
#   ./vidscribe.sh "abc123" "def456"
#   ./vidscribe.sh --skip-newsletter "url1"
#   ./vidscribe.sh --test-newsletter
# =============================================================================

set -e

# Configuration
QUEUE_NAME="${QUEUE_NAME:-vidscribe-prod-video-queue}"
PROCESSOR_LOG_GROUP="${PROCESSOR_LOG_GROUP:-/aws/lambda/vidscribe-prod-processor}"
NEWSLETTER_FUNC="${NEWSLETTER_FUNC:-vidscribe-prod-newsletter}"
TABLE_NAME="${TABLE_NAME:-vidscribe-prod-videos}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"

# Flags
SKIP_NEWSLETTER=false
TEST_NEWSLETTER=false
URLS=()

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

print_step() {
    echo ""
    echo -e "${CYAN}$1 $2${NC}"
}

print_success() {
    echo -e "   ${GREEN}✅ $1${NC}"
}

print_error() {
    echo -e "   ${RED}❌ $1${NC}"
}

print_warning() {
    echo -e "   ${YELLOW}⚠️  $1${NC}"
}

print_info() {
    echo -e "   ${GRAY}$1${NC}"
}

extract_video_id() {
    local input="$1"
    
    # If it's already just an ID (11 chars)
    if [[ "$input" =~ ^[a-zA-Z0-9_-]{11}$ ]]; then
        echo "$input"
        return
    fi
    
    # Extract from various YouTube URL formats
    if [[ "$input" =~ (youtube\.com/watch\?v=|youtu\.be/|youtube\.com/embed/|youtube\.com/v/)([a-zA-Z0-9_-]{11}) ]]; then
        echo "${BASH_REMATCH[2]}"
        return
    fi
    
    # Return as-is
    echo "$input"
}

show_banner() {
    echo -e "${MAGENTA}"
    echo "   ░█░█░▀█▀░█▀▄░█▀▀░█▀▀░█▀▄░▀█▀░█▀▄░█▀▀"
    echo "   ░▀▄▀░░█░░█░█░▀▀█░█░░░█▀▄░░█░░█▀▄░█▀▀"
    echo "   ░░▀░░▀▀▀░▀▀░░▀▀▀░▀▀▀░▀░▀░▀▀▀░▀▀░░▀▀▀"
    echo "   "
    echo "   📺 YouTube to Newsletter Pipeline"
    echo -e "${NC}"
}

show_usage() {
    echo -e "${YELLOW}Usage:${NC}"
    echo -e "  ${GRAY}./vidscribe.sh 'https://youtube.com/watch?v=abc123'${NC}"
    echo -e "  ${GRAY}./vidscribe.sh 'id1' 'id2' --skip-newsletter${NC}"
    echo -e "  ${GRAY}./vidscribe.sh --test-newsletter${NC}"
    echo ""
}

# -----------------------------------------------------------------------------
# Test Newsletter Mode
# -----------------------------------------------------------------------------

invoke_test_newsletter() {
    print_step "🧪" "Test Newsletter Mode"
    
    local now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local ttl=$(( $(date +%s) + 2592000 ))  # 30 days
    local video_id="test-$RANDOM"
    
    print_info "Inserting test summary..."
    print_info "Video ID: $video_id"
    
    local item=$(cat <<EOF
{
    "pk": {"S": "SUMMARY#$video_id"},
    "sk": {"S": "DATA"},
    "gsi1pk": {"S": "SUMMARY"},
    "gsi1sk": {"S": "$now"},
    "video_id": {"S": "$video_id"},
    "title": {"S": "🧪 Test Video - VidScribe Pipeline Test"},
    "channel_title": {"S": "VidScribe Test Channel"},
    "summary": {"S": "Test summary to verify VidScribe pipeline."},
    "published_at": {"S": "$now"},
    "summarized_at": {"S": "$now"},
    "ttl": {"N": "$ttl"}
}
EOF
)

    if aws dynamodb put-item --table-name "$TABLE_NAME" --item "$item" --no-cli-pager 2>/dev/null; then
        print_success "Test data inserted"
    else
        print_error "Failed to insert test data"
        exit 1
    fi

    print_step "📧" "Sending Newsletter"
    
    local temp_file=$(mktemp)
    if aws lambda invoke \
        --function-name "$NEWSLETTER_FUNC" \
        --payload '{}' \
        --cli-binary-format raw-in-base64-out \
        "$temp_file" \
        --no-cli-pager 2>/dev/null; then
        
        local status_code=$(jq -r '.statusCode // empty' "$temp_file" 2>/dev/null)
        
        if [[ "$status_code" == "200" ]]; then
            print_success "Newsletter sent!"
            local summaries=$(jq -r '.body | fromjson | .summaries_count // "?"' "$temp_file" 2>/dev/null)
            print_info "Summaries: $summaries"
        else
            print_error "Newsletter failed"
            cat "$temp_file"
        fi
        rm -f "$temp_file"
    else
        print_error "Failed to invoke newsletter"
        rm -f "$temp_file"
        exit 1
    fi

    echo ""
    echo -e "${GREEN}🎉 Test complete! Check your inbox.${NC}"
    echo ""
}

# -----------------------------------------------------------------------------
# Main Workflow
# -----------------------------------------------------------------------------

invoke_video_workflow() {
    local video_ids=("$@")
    
    # 1. Check AWS Resources
    print_step "🔍" "Checking AWS Resources"
    
    local queue_url
    queue_url=$(aws sqs get-queue-url --queue-name "$QUEUE_NAME" --query 'QueueUrl' --output text 2>/dev/null) || {
        print_error "Failed to find SQS queue. Is the infrastructure deployed?"
        print_info "Run: cd infra && terraform apply"
        exit 1
    }
    print_success "Queue: $QUEUE_NAME"

    local start_time=$(date +%s000)

    # 2. Inject Videos
    print_step "💉" "Injecting ${#video_ids[@]} video(s) into queue"
    
    for vid in "${video_ids[@]}"; do
        local now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        local body=$(cat <<EOF
{"video_id":"$vid","title":"Manual: $vid","channel_id":"MANUAL","channel_title":"Manual Trigger","published_at":"$now"}
EOF
)
        if aws sqs send-message --queue-url "$queue_url" --message-body "$body" --no-cli-pager >/dev/null 2>&1; then
            print_info "→ $vid"
        else
            print_error "Failed to inject $vid"
        fi
    done
    print_success "All videos queued"

    # 3. Monitor Processing
    print_step "⏳" "Waiting for processing (max ${WAIT_TIMEOUT}s)"
    
    local -A pending
    for vid in "${video_ids[@]}"; do
        pending[$vid]=1
    done
    
    local elapsed=0
    local poll_interval=5

    while [[ ${#pending[@]} -gt 0 && $elapsed -lt $WAIT_TIMEOUT ]]; do
        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
        
        local logs
        logs=$(aws logs filter-log-events \
            --log-group-name "$PROCESSOR_LOG_GROUP" \
            --start-time "$start_time" \
            --output json 2>/dev/null) || continue
        
        echo "$logs" | jq -r '.events[]?.message // empty' 2>/dev/null | while read -r msg; do
            if [[ "$msg" =~ "Successfully processed video: "([a-zA-Z0-9_-]+) ]]; then
                local processed_id="${BASH_REMATCH[1]}"
                if [[ -n "${pending[$processed_id]}" ]]; then
                    unset "pending[$processed_id]"
                    print_success "Processed: $processed_id"
                fi
            fi
        done
        
        echo -n "."
    done

    echo ""
    
    if [[ ${#pending[@]} -gt 0 ]]; then
        print_warning "Timeout! Some videos may still be processing."
    else
        print_success "All videos processed!"
    fi

    # 4. Send Newsletter
    if [[ "$SKIP_NEWSLETTER" == "false" ]]; then
        print_step "📧" "Sending Newsletter"
        
        local temp_file=$(mktemp)
        if aws lambda invoke \
            --function-name "$NEWSLETTER_FUNC" \
            --cli-binary-format raw-in-base64-out \
            "$temp_file" \
            --no-cli-pager 2>/dev/null; then
            
            local status_code=$(jq -r '.statusCode // empty' "$temp_file" 2>/dev/null)
            
            if [[ "$status_code" == "200" ]]; then
                print_success "Newsletter sent!"
            else
                print_warning "Newsletter response: $(cat "$temp_file")"
            fi
            rm -f "$temp_file"
        else
            print_error "Failed to invoke newsletter"
            rm -f "$temp_file"
        fi
    else
        print_info "Skipping newsletter (remove --skip-newsletter to send)"
    fi

    echo ""
    echo -e "${MAGENTA}🎉 WORKFLOW COMPLETE${NC}"
    echo ""
}

# -----------------------------------------------------------------------------
# Argument Parsing
# -----------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-newsletter)
            SKIP_NEWSLETTER=true
            shift
            ;;
        --test-newsletter)
            TEST_NEWSLETTER=true
            shift
            ;;
        --timeout)
            WAIT_TIMEOUT="$2"
            shift 2
            ;;
        --help|-h)
            show_banner
            show_usage
            exit 0
            ;;
        *)
            URLS+=("$1")
            shift
            ;;
    esac
done

# -----------------------------------------------------------------------------
# Entry Point
# -----------------------------------------------------------------------------

show_banner

if [[ "$TEST_NEWSLETTER" == "true" ]]; then
    invoke_test_newsletter
    exit 0
fi

if [[ ${#URLS[@]} -eq 0 ]]; then
    print_error "No URLs provided!"
    echo ""
    show_usage
    exit 1
fi

# Extract video IDs from URLs
VIDEO_IDS=()
for url in "${URLS[@]}"; do
    VIDEO_IDS+=("$(extract_video_id "$url")")
done

print_info "Video IDs: ${VIDEO_IDS[*]}"

invoke_video_workflow "${VIDEO_IDS[@]}"
