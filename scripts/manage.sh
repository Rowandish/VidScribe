#!/usr/bin/env bash
# =============================================================================
# 🛠️  VidScribe Management Tool
# =============================================================================
# Unified management console for VidScribe operations.
#
# Usage:
#   ./manage.sh <command> [subcommand] [options]
#
# Commands:
#   channels   list | add <ID> | remove <ID> | clear
#   newsletter frequency <daily|weekly|monthly> | test <VIDEO_URL>
#   errors     Show recent errors
#   logs       <poller|processor|newsletter|cleanup> [--lines N]
#   apikeys    update
#   info       System status dashboard
#   cleanup    run | status
#   retry      list
#   help       Show this help
# =============================================================================

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

PROJECT_NAME="${PROJECT_NAME:-vidscribe}"
STAGE="${STAGE:-prod}"
DAYS_BACK="${DAYS_BACK:-7}"
LOG_LINES="${LOG_LINES:-50}"

SSM_PREFIX="/${PROJECT_NAME}"
TABLE_NAME="${PROJECT_NAME}-${STAGE}-videos"
QUEUE_NAME="${PROJECT_NAME}-${STAGE}-video-queue"
DLQ_NAME="${PROJECT_NAME}-${STAGE}-video-dlq"

LAMBDA_POLLER="${PROJECT_NAME}-${STAGE}-poller"
LAMBDA_PROCESSOR="${PROJECT_NAME}-${STAGE}-processor"
LAMBDA_NEWSLETTER="${PROJECT_NAME}-${STAGE}-newsletter"
LAMBDA_CLEANUP="${PROJECT_NAME}-${STAGE}-cleanup"

declare -A LOG_GROUPS=(
    ["poller"]="/aws/lambda/${LAMBDA_POLLER}"
    ["processor"]="/aws/lambda/${LAMBDA_PROCESSOR}"
    ["newsletter"]="/aws/lambda/${LAMBDA_NEWSLETTER}"
    ["cleanup"]="/aws/lambda/${LAMBDA_CLEANUP}"
)

# =============================================================================
# Colors
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
DARK_CYAN='\033[0;36m'
DARK_GRAY='\033[0;90m'
DARK_RED='\033[0;31m'
NC='\033[0m'

# =============================================================================
# UI Helpers
# =============================================================================

print_banner() {
    echo ""
    echo -e "  ${DARK_CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${DARK_CYAN}║                                                              ║${NC}"
    echo -e "  ${DARK_CYAN}║   ${CYAN}🛠️  VidScribe Management Tool${DARK_CYAN}                            ║${NC}"
    echo -e "  ${DARK_CYAN}║                                                              ║${NC}"
    echo -e "  ${DARK_CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_section() {
    local icon="${2:-▸}"
    echo ""
    echo -e "  ${MAGENTA}${icon} ${WHITE}$1${NC}"
    echo -e "  ${DARK_GRAY}$(printf '─%.0s' {1..60})${NC}"
}

print_row() {
    local label="$1"
    local value="$2"
    local color="${3:-$WHITE}"
    local padding=$((22 - ${#label}))
    [ $padding -lt 1 ] && padding=1
    printf "    ${GRAY}%s${NC}%*s${color}%s${NC}\n" "$label" "$padding" "" "$value"
}

print_ok()   { echo -e "    ${GREEN}✅ $1${NC}"; }
print_err()  { echo -e "    ${RED}❌ $1${NC}"; }
print_warn() { echo -e "    ${YELLOW}⚠️  $1${NC}"; }
print_inf()  { echo -e "    ${DARK_CYAN}ℹ️  $1${NC}"; }

print_table_header() {
    local line="    "
    local separator="    "
    local i=0
    while [ $i -lt ${#COLS[@]} ]; do
        line+=$(printf "%-${WIDTHS[$i]}s" "${COLS[$i]}")
        separator+=$(printf '─%.0s' $(seq 1 $((${WIDTHS[$i]} - 1))))
        separator+=" "
        i=$((i + 1))
    done
    echo -e "${CYAN}${line}${NC}"
    echo -e "${DARK_GRAY}${separator}${NC}"
}

print_table_row() {
    local color="${2:-$WHITE}"
    local line="    "
    local i=0
    while [ $i -lt ${#VALS[@]} ]; do
        local val="${VALS[$i]}"
        local w=${WIDTHS[$i]}
        if [ ${#val} -gt $((w - 2)) ]; then
            val="${val:0:$((w - 5))}..."
        fi
        line+=$(printf "%-${w}s" "$val")
        i=$((i + 1))
    done
    echo -e "${color}${line}${NC}"
}

confirm_action() {
    echo ""
    echo -ne "    ${YELLOW}$1${NC} ${DARK_GRAY}[y/N]${NC} "
    read -r response
    [[ "$response" =~ ^[yY]$ ]]
}

# =============================================================================
# SSM Helpers
# =============================================================================

get_ssm_value() {
    local name="$1"
    local secure="${2:-false}"
    local params="--name ${SSM_PREFIX}/${name} --output json"
    if [ "$secure" = "true" ]; then
        params+=" --with-decryption"
    fi
    aws ssm get-parameter $params 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['Parameter']['Value'])" 2>/dev/null || echo ""
}

set_ssm_value() {
    local name="$1"
    local value="$2"
    local type="${3:-String}"
    aws ssm put-parameter \
        --name "${SSM_PREFIX}/${name}" \
        --value "$value" \
        --type "$type" \
        --overwrite \
        --output json >/dev/null 2>&1
}

get_channel_name() {
    local channel_id="$1"
    local api_key
    api_key=$(get_ssm_value "youtube_api_key" "true")
    if [ -z "$api_key" ] || [ "$api_key" = "PLACEHOLDER_REPLACE_ME" ]; then
        echo "?"
        return
    fi
    local url="https://www.googleapis.com/youtube/v3/channels?part=snippet&id=${channel_id}&key=${api_key}&fields=items/snippet/title"
    local title
    title=$(curl -s "$url" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['items'][0]['snippet']['title'] if d.get('items') else 'Unknown')" 2>/dev/null || echo "?")
    echo "$title"
}

extract_video_id() {
    local url="$1"
    if [[ "$url" =~ ^[a-zA-Z0-9_-]{11}$ ]]; then
        echo "$url"
        return
    fi
    local vid
    vid=$(echo "$url" | python3 -c "import sys,re; m=re.search(r'(?:youtube\.com/watch\?v=|youtu\.be/|youtube\.com/embed/|youtube\.com/v/)([a-zA-Z0-9_-]{11})', sys.stdin.read().strip()); print(m.group(1) if m else sys.stdin.read().strip())" 2>/dev/null)
    echo "${vid:-$url}"
}

get_video_processing_status() {
    local video_id="$1"
    local key_json
    key_json="{\"pk\":{\"S\":\"VIDEO#${video_id}\"},\"sk\":{\"S\":\"METADATA\"}}"
    aws dynamodb get-item \
        --table-name "$TABLE_NAME" \
        --key "$key_json" \
        --consistent-read \
        --output json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Item',{}).get('status',{}).get('S',''))" 2>/dev/null || echo ""
}

get_video_processing_details_json() {
    local video_id="$1"
    local key_json
    key_json="{\"pk\":{\"S\":\"VIDEO#${video_id}\"},\"sk\":{\"S\":\"METADATA\"}}"
    aws dynamodb get-item \
        --table-name "$TABLE_NAME" \
        --key "$key_json" \
        --consistent-read \
        --output json 2>/dev/null | python3 -c "import sys,json; i=json.load(sys.stdin).get('Item',{}); out={'status':i.get('status',{}).get('S',''),'failure_reason':i.get('failure_reason',{}).get('S',''),'error':i.get('error',{}).get('S',''),'next_retry_at':i.get('next_retry_at',{}).get('S','')}; print(json.dumps(out))" 2>/dev/null || echo "{}"
}

get_processor_log_excerpt_for_video() {
    local video_id="$1"
    local start_time="$2"
    local max_lines="${3:-8}"
    local processor_log_group="${LOG_GROUPS[processor]}"
    aws logs tail "$processor_log_group" --since "30m" --format short 2>/dev/null | \
        grep -F "$video_id" | tail -n "$max_lines" || true
}

get_processor_recent_log_excerpt() {
    local start_time="$1"
    local max_lines="${2:-8}"
    local processor_log_group="${LOG_GROUPS[processor]}"
    aws logs tail "$processor_log_group" --since "15m" --format short 2>/dev/null | \
        tail -n "$max_lines" || true
}

print_video_failure_diagnostics() {
    local video_id="$1"
    local start_time="$2"
    local status="${3:-}"

    local details_json
    details_json=$(get_video_processing_details_json "$video_id")

    local db_status reason error_msg next_retry
    db_status=$(echo "$details_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
    reason=$(echo "$details_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('failure_reason',''))" 2>/dev/null || echo "")
    error_msg=$(echo "$details_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error',''))" 2>/dev/null || echo "")
    next_retry=$(echo "$details_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('next_retry_at',''))" 2>/dev/null || echo "")

    [ -z "$status" ] && status="$db_status"
    [ -z "$status" ] && status="FAILED"

    print_err "Failed: $video_id ($status)"
    [ -n "$reason" ] && print_inf "Reason: $reason"

    if [ -n "$error_msg" ]; then
        local short_error="$error_msg"
        [ ${#short_error} -gt 220 ] && short_error="${short_error:0:217}..."
        print_inf "Error: $short_error"
    fi

    [ -n "$next_retry" ] && print_inf "Next retry at: $next_retry"

    local excerpt
    excerpt=$(get_processor_log_excerpt_for_video "$video_id" "$start_time" "8")
    if [ -n "$excerpt" ]; then
        echo -e "      ${DARK_CYAN}Processor log excerpt for $video_id:${NC}"
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            echo -e "      ${GRAY}• $line${NC}"
        done <<< "$excerpt"
    else
        local recent_excerpt
        recent_excerpt=$(get_processor_recent_log_excerpt "$start_time" "8")
        if [ -n "$recent_excerpt" ]; then
            echo -e "      ${DARK_CYAN}Recent processor logs (no direct match for $video_id):${NC}"
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                echo -e "      ${GRAY}• $line${NC}"
            done <<< "$recent_excerpt"
        else
            print_inf "No processor log lines found yet for $video_id (possible CloudWatch ingestion delay)."
        fi
    fi
}

is_key_plausible() {
    local val="$1"
    [ -z "$val" ] && return 1
    [ "$val" = "PLACEHOLDER_REPLACE_ME" ] && return 1
    [ "$val" = "PLACEHOLDER" ] && return 1
    [ ${#val} -lt 10 ] && return 1
    return 0
}

is_value_configured() {
    local val="$1"
    [ -z "$val" ] && return 1
    [ "$val" = "PLACEHOLDER_REPLACE_ME" ] && return 1
    [ "$val" = "PLACEHOLDER" ] && return 1
    return 0
}

is_email_plausible() {
    local val="$1"
    [ -z "$val" ] && return 1
    [ "$val" = "PLACEHOLDER" ] && return 1
    [ ${#val} -lt 5 ] && return 1
    [[ "$val" == *@*.* ]] && return 0
    return 1
}


# =============================================================================
# Command: channels
# =============================================================================

cmd_channels() {
    local sub="${1:-list}"
    local arg="${2:-}"

    case "$sub" in
        list)
            print_section "Monitored Channels" "📺"
            local raw
            raw=$(get_ssm_value "youtube_channels")
            if [ -z "$raw" ]; then
                print_warn "Could not read channels configuration"
                return
            fi
            local channels
            channels=$(echo "$raw" | python3 -c "import sys,json; ch=json.load(sys.stdin); [print(c) for c in ch]" 2>/dev/null)
            if [ -z "$channels" ]; then
                print_inf "No channels configured"
                return
            fi
            local COLS=("#" "Channel ID" "Name")
            local WIDTHS=(5 28 30)
            print_table_header
            local idx=1
            while IFS= read -r ch; do
                local name
                name=$(get_channel_name "$ch")
                local VALS=("$idx" "$ch" "$name")
                print_table_row "$WHITE"
                idx=$((idx + 1))
            done <<< "$channels"
            echo ""
            print_inf "Total: $((idx - 1)) channel(s)"
            ;;
        add)
            if [ -z "$arg" ]; then
                print_err "Usage: ./manage.sh channels add <CHANNEL_ID>"
                return
            fi
            print_section "Add Channel" "➕"
            local raw
            raw=$(get_ssm_value "youtube_channels")
            local channels="${raw:-[]}"

            if echo "$channels" | python3 -c "import sys,json; ch=json.load(sys.stdin); sys.exit(0 if '$arg' in ch else 1)" 2>/dev/null; then
                print_warn "Channel $arg is already monitored"
                return
            fi

            local name
            name=$(get_channel_name "$arg")
            print_inf "Channel: $arg ($name)"

            local new_channels
            new_channels=$(echo "$channels" | python3 -c "import sys,json; ch=json.load(sys.stdin); ch.append('$arg'); print(json.dumps(ch))")
            set_ssm_value "youtube_channels" "$new_channels"
            local count
            count=$(echo "$new_channels" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
            print_ok "Channel added successfully. Total: $count"
            ;;
        remove)
            if [ -z "$arg" ]; then
                print_err "Usage: ./manage.sh channels remove <CHANNEL_ID>"
                return
            fi
            print_section "Remove Channel" "➖"
            local raw
            raw=$(get_ssm_value "youtube_channels")
            local channels="${raw:-[]}"

            if ! echo "$channels" | python3 -c "import sys,json; ch=json.load(sys.stdin); sys.exit(0 if '$arg' in ch else 1)" 2>/dev/null; then
                print_warn "Channel $arg is not in the monitored list"
                return
            fi

            local name
            name=$(get_channel_name "$arg")
            print_inf "Removing: $arg ($name)"

            local new_channels
            new_channels=$(echo "$channels" | python3 -c "import sys,json; ch=json.load(sys.stdin); ch.remove('$arg'); print(json.dumps(ch))")
            set_ssm_value "youtube_channels" "$new_channels"
            local count
            count=$(echo "$new_channels" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
            print_ok "Channel removed. Remaining: $count"
            ;;
        clear)
            print_section "Clear All Channels" "🗑️"
            local raw
            raw=$(get_ssm_value "youtube_channels")
            local count
            count=$(echo "${raw:-[]}" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

            if [ "$count" = "0" ]; then
                print_inf "No channels to remove"
                return
            fi

            print_warn "This will remove all $count monitored channels"
            if ! confirm_action "Are you sure?"; then
                print_inf "Cancelled"
                return
            fi

            set_ssm_value "youtube_channels" "[]"
            print_ok "All channels removed"
            ;;
        *)
            print_err "Usage: ./manage.sh channels <list|add|remove|clear> [ID]"
            ;;
    esac
}

# =============================================================================
# Command: newsletter
# =============================================================================

cmd_newsletter() {
    local sub="${1:-}"
    local arg="${2:-}"

    case "$sub" in
        frequency)
            print_section "Newsletter Frequency" "📬"

            if [ -z "$arg" ]; then
                local rule
                rule=$(aws events describe-rule --name "${LAMBDA_NEWSLETTER}-schedule" --output json 2>/dev/null || echo "")
                if [ -n "$rule" ]; then
                    local schedule
                    schedule=$(echo "$rule" | python3 -c "import sys,json; print(json.load(sys.stdin)['ScheduleExpression'])")
                    print_row "Current schedule" "$schedule" "$CYAN"
                fi
                echo ""
                print_inf "Usage: ./manage.sh newsletter frequency <daily|weekly|monthly>"
                return
            fi

            local cron_expr
            case "$arg" in
                daily)   cron_expr="rate(1 day)" ;;
                weekly)  cron_expr="rate(7 days)" ;;
                monthly) cron_expr="cron(0 9 1 * ? *)" ;;
                *)
                    print_err "Invalid frequency: $arg. Use: daily, weekly, monthly"
                    return
                    ;;
            esac

            aws events put-rule \
                --name "${LAMBDA_NEWSLETTER}-schedule" \
                --schedule-expression "$cron_expr" \
                --state ENABLED \
                --output json >/dev/null 2>&1

            print_ok "Newsletter schedule updated to: $arg ($cron_expr)"
            ;;
        test)
            print_section "Send Test Newsletter" "📧"

            print_inf "Invoking newsletter Lambda..."
            local payload='{"source":"manual-test","detail-type":"Manual Test"}'
            local tmp_file
            tmp_file=$(mktemp)
            aws lambda invoke \
                --function-name "$LAMBDA_NEWSLETTER" \
                --payload "$payload" \
                --cli-binary-format raw-in-base64-out \
                "$tmp_file" >/dev/null 2>&1

            if [ -f "$tmp_file" ]; then
                local status_code summaries recipient
                status_code=$(cat "$tmp_file" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('statusCode', 0))" 2>/dev/null || echo "0")
                if [ "$status_code" = "200" ]; then
                    print_ok "Test newsletter sent successfully"
                    summaries=$(cat "$tmp_file" | python3 -c "import sys,json; b=json.loads(json.load(sys.stdin)['body']); print(b.get('summaries_count','?'))" 2>/dev/null || echo "?")
                    recipient=$(cat "$tmp_file" | python3 -c "import sys,json; b=json.loads(json.load(sys.stdin)['body']); print(b.get('recipient','?'))" 2>/dev/null || echo "?")
                    print_row "Summaries" "$summaries" "$CYAN"
                    print_row "Recipient" "$recipient" "$WHITE"
                else
                    print_err "Newsletter invocation failed (status: $status_code)"
                fi
                rm -f "$tmp_file"
            fi
            ;;
        test-insert)
            print_section "Insert Test Summary & Send Newsletter" "🧪"

            local now video_id ttl
            now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            ttl=$(python3 -c "import time; print(int(time.time()) + 30*86400)")
            video_id="test-$((RANDOM % 9000 + 1000))"

            print_inf "Inserting test summary (ID: $video_id)..."

            local item
            item=$(python3 -c "
import json
item = {
    'pk': {'S': 'SUMMARY#$video_id'},
    'sk': {'S': 'DATA'},
    'gsi1pk': {'S': 'SUMMARY'},
    'gsi1sk': {'S': '$now'},
    'video_id': {'S': '$video_id'},
    'title': {'S': '🧪 Test Video - VidScribe Pipeline Test'},
    'channel_title': {'S': 'VidScribe Test Channel'},
    'summary': {'S': 'This is a test video to verify VidScribe works correctly.\n\n**Features tested:**\n- DynamoDB data insertion\n- Newsletter Lambda invocation\n- HTML email formatting\n- Send via SES or Gmail\n\nIf you receive this email, the system is operational! 🎉'},
    'published_at': {'S': '$now'},
    'summarized_at': {'S': '$now'},
    'ttl': {'N': '$ttl'}
}
print(json.dumps(item))
")

            aws dynamodb put-item \
                --table-name "$TABLE_NAME" \
                --item "$item" \
                --no-cli-pager >/dev/null 2>&1 || { print_err "Failed to insert test data"; return; }
            print_ok "Test data inserted"

            print_inf "Invoking newsletter Lambda..."
            local tmp_file
            tmp_file=$(mktemp)
            aws lambda invoke \
                --function-name "$LAMBDA_NEWSLETTER" \
                --payload '{}' \
                --cli-binary-format raw-in-base64-out \
                "$tmp_file" \
                --no-cli-pager >/dev/null 2>&1

            if [ -f "$tmp_file" ]; then
                local status_code
                status_code=$(cat "$tmp_file" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('statusCode', 0))" 2>/dev/null || echo "0")
                if [ "$status_code" = "200" ]; then
                    print_ok "Newsletter sent!"
                    local summaries recipient
                    summaries=$(cat "$tmp_file" | python3 -c "import sys,json; b=json.loads(json.load(sys.stdin)['body']); print(b.get('summaries_count','?'))" 2>/dev/null || echo "?")
                    recipient=$(cat "$tmp_file" | python3 -c "import sys,json; b=json.loads(json.load(sys.stdin)['body']); print(b.get('recipient','?'))" 2>/dev/null || echo "?")
                    print_row "Summaries" "$summaries" "$CYAN"
                    print_row "Recipient" "$recipient" "$WHITE"
                else
                    print_err "Newsletter failed"
                fi
                rm -f "$tmp_file"
            fi

            echo ""
            print_inf "Cleanup: aws dynamodb delete-item --table-name $TABLE_NAME --key '{\"pk\":{\"S\":\"SUMMARY#$video_id\"},\"sk\":{\"S\":\"DATA\"}}'"
            ;;
        *)
            print_err "Usage: ./manage.sh newsletter <frequency|test|test-insert> [value]"
            ;;
    esac
}

# =============================================================================
# Command: errors
# =============================================================================

cmd_errors() {
    print_section "Error Report (last $DAYS_BACK days)" "🏥"

    # 1. DynamoDB failed videos
    echo ""
    echo -e "    ${YELLOW}📊 ${WHITE}Failed Videos in DynamoDB${NC}"

    local scan_result
    scan_result=$(aws dynamodb scan \
        --table-name "$TABLE_NAME" \
        --filter-expression "#s = :failed OR #s = :permfailed" \
        --expression-attribute-names '{"#s":"status"}' \
        --expression-attribute-values '{":failed":{"S":"FAILED"},":permfailed":{"S":"PERMANENTLY_FAILED"}}' \
        --projection-expression "video_id, title, failure_reason, failed_at, retry_count, #s" \
        --output json 2>/dev/null || echo '{"Items":[]}')

    local count
    count=$(echo "$scan_result" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('Items',[])))")

    if [ "$count" = "0" ]; then
        print_ok "No failed videos found"
    else
        local COLS=("Video ID" "Reason" "Retries" "Status" "Failed At")
        local WIDTHS=(14 22 10 20 24)
        print_table_header

        echo "$scan_result" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('Items', []):
    vid = item.get('video_id', {}).get('S', '?')
    reason = item.get('failure_reason', {}).get('S', '?')
    retries = item.get('retry_count', {}).get('N', '0')
    status = item.get('status', {}).get('S', 'FAILED')
    failed = item.get('failed_at', {}).get('S', '?')
    print(f'{vid}|{reason}|{retries}|{status}|{failed}')
" 2>/dev/null | while IFS='|' read -r vid reason retries status failed; do
            local color="$YELLOW"
            [ "$status" = "PERMANENTLY_FAILED" ] && color="$RED"
            local VALS=("$vid" "$reason" "$retries" "$status" "$failed")
            print_table_row "$color"
        done

        echo ""
        print_inf "Total failed: $count"
    fi

    # 2. DLQ
    echo ""
    echo -e "    ${YELLOW}📬 ${WHITE}Dead Letter Queue${NC}"
    local queue_url
    queue_url=$(aws sqs get-queue-url --queue-name "$DLQ_NAME" --output json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['QueueUrl'])" 2>/dev/null || echo "")

    if [ -n "$queue_url" ]; then
        local msg_count
        msg_count=$(aws sqs get-queue-attributes --queue-url "$queue_url" --attribute-names ApproximateNumberOfMessages --output json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['Attributes']['ApproximateNumberOfMessages'])" 2>/dev/null || echo "0")
        if [ "$msg_count" = "0" ]; then
            print_ok "DLQ is empty"
        else
            print_err "$msg_count message(s) in the Dead Letter Queue"
        fi
    else
        print_warn "Could not check DLQ"
    fi

    # 3. Lambda errors
    echo ""
    echo -e "    ${YELLOW}📋 ${WHITE}Recent Lambda Errors${NC}"

    local start_time
    start_time=$(python3 -c "from datetime import datetime, timedelta, timezone; print(int((datetime.now(timezone.utc) - timedelta(days=$DAYS_BACK)).timestamp() * 1000))")
    local end_time
    end_time=$(python3 -c "from datetime import datetime, timezone; print(int(datetime.now(timezone.utc).timestamp() * 1000))")

    for func in poller processor newsletter cleanup; do
        local log_group="${LOG_GROUPS[$func]}"
        local events
        events=$(aws logs filter-log-events \
            --log-group-name "$log_group" \
            --filter-pattern "ERROR" \
            --start-time "$start_time" \
            --end-time "$end_time" \
            --limit 5 \
            --output json 2>/dev/null || echo "")

        if [ -z "$events" ]; then
            print_inf "$func: Log group not found"
            continue
        fi

        local err_count
        err_count=$(echo "$events" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('events',[])))" 2>/dev/null || echo "0")

        if [ "$err_count" != "0" ] && [ "$err_count" != "" ]; then
            print_err "$func: $err_count error(s)"
            echo "$events" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for ev in data.get('events', [])[:3]:
    msg = ev.get('message', '').strip()
    print(f'       └─ {msg}')
" 2>/dev/null
        else
            print_ok "$func: No errors"
        fi
    done
}

# =============================================================================
# Command: logs
# =============================================================================

cmd_logs() {
    local func="${1:-}"

    if [ -z "$func" ] || [ -z "${LOG_GROUPS[$func]+x}" ]; then
        print_section "CloudWatch Logs" "📋"
        print_err "Usage: ./manage.sh logs <poller|processor|newsletter|cleanup> [--lines N]"
        print_inf "Available log groups:"
        for key in "${!LOG_GROUPS[@]}"; do
            echo -e "      ${CYAN}• ${key}${NC}"
        done
        return
    fi

    local log_group="${LOG_GROUPS[$func]}"
    print_section "Logs: $func (last $LOG_LINES events)" "📋"

    aws logs tail "$log_group" --since "1h" --format short 2>/dev/null | tail -n "$LOG_LINES" | while IFS= read -r line; do
        echo -e "    ${GRAY}${line}${NC}"
    done
}

# =============================================================================
# Command: apikeys
# =============================================================================

cmd_apikeys() {
    print_section "API Key Management" "🔑"

    echo ""
    echo -e "    ${WHITE}Select which key to update:${NC}"
    echo -e "      ${CYAN}1) YouTube Data API Key${NC}"
    echo -e "      ${CYAN}2) LLM API Key (Gemini/Groq)${NC}"
    echo -e "      ${CYAN}3) Gmail App Password${NC}"
    echo -e "      ${CYAN}4) Webshare Proxy Credentials${NC}"
    echo -e "      ${DARK_GRAY}0) Cancel${NC}"
    echo ""
    echo -n "    Choice: "
    read -r choice

    case "$choice" in
        1)
            echo -n "    Enter new YouTube API key: "
            read -r key
            if [ -n "$key" ]; then
                set_ssm_value "youtube_api_key" "$key" "SecureString"
                print_ok "YouTube API key updated"
            fi
            ;;
        2)
            echo -n "    Enter new LLM API key: "
            read -r key
            if [ -n "$key" ]; then
                set_ssm_value "llm_api_key" "$key" "SecureString"
                print_ok "LLM API key updated"
            fi
            ;;
        3)
            echo -n "    Enter new Gmail App Password: "
            read -r key
            if [ -n "$key" ]; then
                set_ssm_value "gmail_app_password" "$key" "SecureString"
                print_ok "Gmail App Password updated"
            fi
            ;;
        4)
            echo -n "    Enter Webshare username: "
            read -r user
            echo -n "    Enter Webshare password: "
            read -r pass
            if [ -n "$user" ] && [ -n "$pass" ]; then
                set_ssm_value "webshare_username" "$user"
                set_ssm_value "webshare_password" "$pass" "SecureString"
                set_ssm_value "proxy_type" "webshare"
                print_ok "Webshare credentials updated"
            fi
            ;;
        *)
            print_inf "Cancelled"
            ;;
    esac
}

# =============================================================================
# Command: info
# =============================================================================

cmd_info() {
    print_section "System Information" "📊"
    local issues=()

    # --- Channels ---
    local raw ch_count
    raw=$(get_ssm_value "youtube_channels")
    ch_count=$(echo "${raw:-[]}" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
    print_row "Channels" "$ch_count monitored" "$CYAN"
    if [ "$ch_count" = "0" ]; then
        print_warn "No YouTube channels configured"
        issues+=("No YouTube channels configured — run: ./manage.sh channels add <ID>")
    fi

    # --- Newsletter schedule ---
    local rule
    rule=$(aws events describe-rule --name "${LAMBDA_NEWSLETTER}-schedule" --output json 2>/dev/null || echo "")
    if [ -n "$rule" ]; then
        local sched state friendly sched_color
        sched=$(echo "$rule" | python3 -c "import sys,json; print(json.load(sys.stdin)['ScheduleExpression'])")
        state=$(echo "$rule" | python3 -c "import sys,json; print(json.load(sys.stdin)['State'])")

        case "$sched" in
            "rate(1 day)")  friendly="Daily" ;;
            "rate(7 days)") friendly="Weekly" ;;
            *"1 * ? *"*)    friendly="Monthly" ;;
            *)              friendly="$sched" ;;
        esac
        sched_color="$CYAN"
        [ "$state" != "ENABLED" ] && sched_color="$YELLOW"
        print_row "Newsletter" "$friendly ($state)" "$sched_color"
        if [ "$state" != "ENABLED" ]; then
            print_warn "Newsletter EventBridge rule is DISABLED"
            issues+=("Newsletter schedule is DISABLED — newsletter will not be sent automatically")
        fi
    else
        print_row "Newsletter" "Could not read schedule" "$YELLOW"
        issues+=("Could not read newsletter EventBridge rule — is infrastructure deployed?")
    fi

    # --- Email configuration ---
    local sender dest use_gmail email_method
    sender=$(get_ssm_value "sender_email")
    dest=$(get_ssm_value "destination_email")
    use_gmail=$(get_ssm_value "use_gmail_smtp")
    email_method="Amazon SES"
    [ "$use_gmail" = "true" ] && email_method="Gmail SMTP"

    print_row "Email method" "$email_method" "$CYAN"

    if is_email_plausible "$sender"; then
        print_row "Sender" "✅ $sender" "$GREEN"
    else
        print_row "Sender" "❌ Not set or invalid" "$RED"
        issues+=("Sender email not configured — run: ./manage.sh email configure")
    fi

    if is_email_plausible "$dest"; then
        print_row "Destination" "✅ $dest" "$GREEN"
    else
        print_row "Destination" "❌ Not set or invalid" "$RED"
        issues+=("Destination email not configured — run: ./manage.sh email configure")
    fi

    # SES verification check (only if using SES)
    if [ "$use_gmail" != "true" ]; then
        local ses_result
        ses_result=$(aws ses get-identity-verification-attributes \
            --identities "$sender" "$dest" \
            --output json 2>/dev/null || echo "")
        if [ -n "$ses_result" ]; then
            for email in "$sender" "$dest"; do
                [ -z "$email" ] && continue
                local ver_status
                ver_status=$(echo "$ses_result" | python3 -c "import sys,json; d=json.load(sys.stdin); a=d.get('VerificationAttributes',{}).get('$email',{}); print(a.get('VerificationStatus',''))" 2>/dev/null || echo "")
                if [ "$ver_status" = "Success" ]; then
                    print_row "  SES: $email" "✅ Verified" "$GREEN"
                else
                    print_row "  SES: $email" "❌ Not verified" "$RED"
                    issues+=("SES email '$email' is not verified — check your inbox for verification link")
                fi
            done
        else
            print_warn "Could not check SES verification status"
        fi
    else
        # Gmail checks
        local gmail_sender gmail_pass
        gmail_sender=$(get_ssm_value "gmail_sender")
        gmail_pass=$(get_ssm_value "gmail_app_password" "true")
        if is_email_plausible "$gmail_sender"; then
            print_row "Gmail sender" "✅ $gmail_sender" "$GREEN"
        else
            print_row "Gmail sender" "❌ Not set" "$RED"
            issues+=("Gmail sender not configured — run: ./manage.sh email configure")
        fi
        if is_key_plausible "$gmail_pass"; then
            print_row "Gmail app password" "✅ Configured" "$GREEN"
        else
            print_row "Gmail app password" "❌ Not set" "$RED"
            issues+=("Gmail app password not configured — run: ./manage.sh apikeys")
        fi
    fi

    # --- LLM ---
    local llm_config
    llm_config=$(get_ssm_value "llm_config")
    if [ -n "$llm_config" ]; then
        local provider model language
        provider=$(echo "$llm_config" | python3 -c "import sys,json; print(json.load(sys.stdin).get('provider','?'))")
        model=$(echo "$llm_config" | python3 -c "import sys,json; print(json.load(sys.stdin).get('model','?'))")
        language=$(echo "$llm_config" | python3 -c "import sys,json; print(json.load(sys.stdin).get('language','English'))")
        print_row "LLM provider" "$provider / $model" "$CYAN"
        print_row "Language" "$language" "$WHITE"
    fi

    # --- API Keys (with plausibility checks) ---
    echo ""
    echo -e "    ${YELLOW}🔑 ${WHITE}API Keys${NC}"

    local yt_key llm_key
    yt_key=$(get_ssm_value "youtube_api_key" "true")
    llm_key=$(get_ssm_value "llm_api_key" "true")

    if is_key_plausible "$yt_key"; then
        print_row "YouTube API key" "✅ Configured (${#yt_key} chars)" "$GREEN"
    else
        print_row "YouTube API key" "❌ Not set or placeholder" "$RED"
        issues+=("YouTube API key is missing or invalid — run: ./manage.sh apikeys")
    fi

    if is_key_plausible "$llm_key"; then
        print_row "LLM API key" "✅ Configured (${#llm_key} chars)" "$GREEN"
    else
        print_row "LLM API key" "❌ Not set or placeholder" "$RED"
        issues+=("LLM API key is missing or invalid — run: ./manage.sh apikeys")
    fi

    # --- Proxy ---
    local proxy_type
    proxy_type=$(get_ssm_value "proxy_type")
    if [ "$proxy_type" = "webshare" ]; then
        local ws_user ws_pass
        ws_user=$(get_ssm_value "webshare_username")
        ws_pass=$(get_ssm_value "webshare_password" "true")
        if is_value_configured "$ws_user" && is_value_configured "$ws_pass"; then
            print_row "Proxy" "✅ Webshare ($ws_user)" "$GREEN"
        else
            print_row "Proxy" "❌ Webshare selected but credentials missing" "$RED"
            issues+=("Webshare proxy selected but credentials not set — run: ./manage.sh apikeys")
        fi
    elif [ "$proxy_type" = "generic" ]; then
        local gen_http
        gen_http=$(get_ssm_value "generic_proxy_http_url" "true")
        if is_value_configured "$gen_http"; then
            print_row "Proxy" "✅ Generic proxy" "$GREEN"
        else
            print_row "Proxy" "❌ Generic proxy selected but URL missing" "$RED"
            issues+=("Generic proxy selected but URL not configured")
        fi
    else
        print_row "Proxy" "❌ None (Required)" "$RED"
        issues+=("Proxy is not configured — YouTube will block requests. Run: ./manage.sh apikeys")
    fi

    # --- DynamoDB stats ---
    echo ""
    echo -e "    ${YELLOW}📊 ${WHITE}DynamoDB Statistics${NC}"

    local total
    total=$(aws dynamodb scan --table-name "$TABLE_NAME" --select "COUNT" --output json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('Count',0))" 2>/dev/null || echo "?")
    print_row "Total records" "$total" "$CYAN"

    for status in QUEUED PROCESSED FAILED PERMANENTLY_FAILED; do
        local count color
        count=$(aws dynamodb scan \
            --table-name "$TABLE_NAME" \
            --filter-expression "#s = :status" \
            --expression-attribute-names '{"#s":"status"}' \
            --expression-attribute-values "{\":status\":{\"S\":\"$status\"}}" \
            --select "COUNT" \
            --output json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('Count',0))" 2>/dev/null || echo "?")

        case "$status" in
            PROCESSED)          color="$GREEN" ;;
            QUEUED)             color="$CYAN" ;;
            FAILED)             color="$YELLOW" ;;
            PERMANENTLY_FAILED) color="$RED" ;;
            *)                  color="$WHITE" ;;
        esac
        print_row "  $status" "$count" "$color"
    done

    # --- DLQ ---
    local queue_url dlq_count dlq_color
    queue_url=$(aws sqs get-queue-url --queue-name "$DLQ_NAME" --output json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['QueueUrl'])" 2>/dev/null || echo "")
    if [ -n "$queue_url" ]; then
        dlq_count=$(aws sqs get-queue-attributes --queue-url "$queue_url" --attribute-names ApproximateNumberOfMessages --output json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['Attributes']['ApproximateNumberOfMessages'])" 2>/dev/null || echo "?")
        dlq_color="$GREEN"
        [ "$dlq_count" != "0" ] && dlq_color="$RED"
        print_row "DLQ messages" "$dlq_count" "$dlq_color"
        if [ "$dlq_count" != "0" ] && [ "$dlq_count" != "?" ]; then
            issues+=("$dlq_count message(s) in DLQ — run: ./manage.sh errors")
        fi
    fi

    # --- Lambda functions ---
    echo ""
    echo -e "    ${YELLOW}⚡ ${WHITE}Lambda Functions${NC}"

    for func in "$LAMBDA_POLLER" "$LAMBDA_PROCESSOR" "$LAMBDA_NEWSLETTER" "$LAMBDA_CLEANUP"; do
        local short_name="${func##*-}"
        local info
        info=$(aws lambda get-function --function-name "$func" --output json 2>/dev/null || echo "")
        if [ -n "$info" ]; then
            local runtime memory timeout last_mod
            runtime=$(echo "$info" | python3 -c "import sys,json; print(json.load(sys.stdin)['Configuration']['Runtime'])")
            memory=$(echo "$info" | python3 -c "import sys,json; print(json.load(sys.stdin)['Configuration']['MemorySize'])")
            timeout=$(echo "$info" | python3 -c "import sys,json; print(json.load(sys.stdin)['Configuration']['Timeout'])")
            last_mod=$(echo "$info" | python3 -c "import sys,json; print(json.load(sys.stdin)['Configuration']['LastModified'][:19])")
            print_row "  $short_name" "✅ ${runtime} | ${memory}MB | ${timeout}s | $last_mod" "$GREEN"
        else
            print_row "  $short_name" "❌ Not deployed" "$RED"
            issues+=("Lambda '$short_name' is not deployed — run: ./manage.sh deploy")
        fi
    done

    # --- Health Summary ---
    echo ""
    if [ ${#issues[@]} -eq 0 ]; then
        echo -e "    ${GREEN}🟢 Health check: All OK${NC}"
    else
        echo -e "    ${RED}🔴 Health check: ${#issues[@]} issue(s) found${NC}"
        echo ""
        for issue in "${issues[@]}"; do
            print_err "$issue"
        done
    fi
}

# =============================================================================
# Command: cleanup
# =============================================================================

cmd_cleanup() {
    local sub="${1:-}"

    case "$sub" in
        run)
            print_section "Manual Cleanup" "🧹"
            print_inf "Invoking cleanup Lambda..."

            local payload='{"source":"manual","detail-type":"Manual Cleanup"}'
            local tmp_file
            tmp_file=$(mktemp)

            aws lambda invoke \
                --function-name "$LAMBDA_CLEANUP" \
                --payload "$payload" \
                --cli-binary-format raw-in-base64-out \
                "$tmp_file" >/dev/null 2>&1

            if [ -f "$tmp_file" ]; then
                local result
                result=$(cat "$tmp_file")
                rm -f "$tmp_file"

                local status_code
                status_code=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('statusCode',0))" 2>/dev/null || echo "0")

                if [ "$status_code" = "200" ]; then
                    print_ok "Cleanup complete"
                    echo "$result" | python3 -c "
import sys, json
body = json.loads(json.load(sys.stdin)['body'])
stats = body.get('stats', {})
print(f'    Scanned:  {stats.get(\"scanned\", 0)}')
print(f'    Deleted:  {stats.get(\"deleted\", 0)}')
print(f'    Errors:   {stats.get(\"errors\", 0)}')
" 2>/dev/null
                else
                    print_err "Cleanup failed"
                fi
            fi
            ;;
        status)
            print_section "Cleanup Status" "🧹"
            local count
            count=$(aws dynamodb scan \
                --table-name "$TABLE_NAME" \
                --filter-expression "#s = :status" \
                --expression-attribute-names '{"#s":"status"}' \
                --expression-attribute-values '{":status":{"S":"PERMANENTLY_FAILED"}}' \
                --select "COUNT" \
                --output json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('Count',0))" 2>/dev/null || echo "?")
            local color="$GREEN"
            [ "$count" != "0" ] && color="$YELLOW"
            print_row "Permanently failed" "$count record(s)" "$color"
            ;;
        *)
            print_err "Usage: ./manage.sh cleanup <run|status>"
            ;;
    esac
}

# =============================================================================
# Command: retry
# =============================================================================

cmd_retry() {
    print_section "Retryable Videos (NO_TRANSCRIPT)" "🔄"

    local scan_result
    scan_result=$(aws dynamodb scan \
        --table-name "$TABLE_NAME" \
        --filter-expression "#s = :status AND failure_reason = :reason" \
        --expression-attribute-names '{"#s":"status"}' \
        --expression-attribute-values '{":status":{"S":"FAILED"},":reason":{"S":"NO_TRANSCRIPT"}}' \
        --projection-expression "video_id, title, retry_count, next_retry_at, first_failed_at" \
        --output json 2>/dev/null || echo '{"Items":[]}')

    local count
    count=$(echo "$scan_result" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('Items',[])))")

    if [ "$count" = "0" ]; then
        print_ok "No videos awaiting transcript retry"
        return
    fi

    local COLS=("Video ID" "Retry #" "Next Retry" "First Failed")
    local WIDTHS=(14 10 26 26)
    print_table_header

    echo "$scan_result" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('Items', []):
    vid = item.get('video_id', {}).get('S', '?')
    retries = item.get('retry_count', {}).get('N', '0')
    next_r = item.get('next_retry_at', {}).get('S', 'N/A')
    first_f = item.get('first_failed_at', {}).get('S', '?')
    print(f'{vid}|{retries}|{next_r}|{first_f}')
" 2>/dev/null | while IFS='|' read -r vid retries next_r first_f; do
        local VALS=("$vid" "$retries" "$next_r" "$first_f")
        print_table_row "$YELLOW"
    done

    echo ""
    print_inf "Total: $count video(s) awaiting retry"
}

# =============================================================================
# Command: help
# =============================================================================

cmd_help() {
    print_banner

    echo -e "  ${WHITE}USAGE${NC}"
    echo -e "    ${GRAY}./manage.sh <command> [subcommand] [options]${NC}"
    echo ""

    echo -e "  ${WHITE}COMMANDS${NC}"
    echo ""

    declare -a help_cmds=(
        "deploy:Deploy infrastructure changes (Terraform)"
        "channels list:List monitored channels with names"
        "channels add <ID>:Add a YouTube channel by ID"
        "channels remove <ID>:Remove a channel by ID"
        "channels clear:Remove all monitored channels"
        "process <URL> [URL2...]:Process video(s): queue + monitor + newsletter"
        "newsletter frequency <f>:Set frequency: daily, weekly, monthly"
        "newsletter test:Invoke newsletter Lambda (send with existing data)"
        "newsletter test-insert:Insert test summary + send newsletter"
        "errors:Show failed videos, DLQ, Lambda errors"
        "logs <function>:Tail CloudWatch logs (poller/processor/...)"
        "apikeys:Interactive API key update wizard"
        "info:System status + health check dashboard"
        "cleanup run:Manually trigger DynamoDB cleanup"
        "cleanup status:Show permanently failed record count"
        "retry list:Show videos awaiting transcript retry"
        "email method <ses|gmail>:Switch email provider"
        "email configure:Configure email settings"
        "help:Show this help message"
    )

    for entry in "${help_cmds[@]}"; do
        local cmd="${entry%%:*}"
        local desc="${entry#*:}"
        printf "    ${CYAN}%-30s${NC}${GRAY}%s${NC}\n" "$cmd" "$desc"
    done

    echo ""
    echo -e "  ${WHITE}OPTIONS${NC}"
    echo -e "    ${GRAY}--lines <N>           Number of log lines to show (default: 50)${NC}"
    echo -e "    ${GRAY}--days-back <N>       Days to look back for errors (default: 7)${NC}"
    echo -e "    ${GRAY}--project <name>      Project name prefix (default: vidscribe)${NC}"
    echo -e "    ${GRAY}--stage <stage>       Deployment stage (default: prod)${NC}"
    echo ""

    echo -e "  ${WHITE}EXAMPLES${NC}"
    echo -e "    ${DARK_GRAY}./manage.sh channels add \"UCBcRF18a7Qf58cCRy5xuWwQ\"${NC}"
    echo -e "    ${DARK_GRAY}./manage.sh process \"https://youtube.com/watch?v=abc123\"${NC}"
    echo -e "    ${DARK_GRAY}./manage.sh newsletter frequency weekly${NC}"
    echo -e "    ${DARK_GRAY}./manage.sh newsletter test-insert${NC}"
    echo -e "    ${DARK_GRAY}./manage.sh logs processor --lines 100${NC}"
    echo -e "    ${DARK_GRAY}./manage.sh info${NC}"
    echo ""
}

# =============================================================================
# Argument Parsing
# =============================================================================

COMMAND=""
SUBCOMMAND=""
ARGUMENT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --lines)    LOG_LINES="$2"; shift 2 ;;
        --days-back) DAYS_BACK="$2"; shift 2 ;;
        --project)  PROJECT_NAME="$2"; shift 2 ;;
        --stage)    STAGE="$2"; shift 2 ;;
        *)
            if [ -z "$COMMAND" ]; then
                COMMAND="$1"
            elif [ -z "$SUBCOMMAND" ]; then
                SUBCOMMAND="$1"
            elif [ -z "$ARGUMENT" ]; then
                ARGUMENT="$1"
            fi
            shift
            ;;
    esac
done

# =============================================================================
# Main Router
# =============================================================================

print_banner




cmd_email() {
    local sub="${1:-}"
    local arg="${2:-}"

    case "$sub" in
        method)
            if [[ "$arg" != "ses" && "$arg" != "gmail" ]]; then
                print_err "Usage: ./manage.sh email method <ses|gmail>"
                return
            fi
            print_section "Email Method: $arg" "📧"
            
            local use_gmail="false"
            [ "$arg" = "gmail" ] && use_gmail="true"
            
            # Update SSM
            set_ssm_value "use_gmail_smtp" "$use_gmail"
            print_ok "Email method updated to $arg"
            ;;
        configure)
            print_section "Configure Email" "📧"
            
            echo -n "    Sender Email (SES verified or Gmail address): "
            read -r sender
            if [ -n "$sender" ]; then
                set_ssm_value "sender_email" "$sender"
                print_ok "Sender updated"
            fi
            
            echo -n "    Destination Email: "
            read -r dest
            if [ -n "$dest" ]; then
                set_ssm_value "destination_email" "$dest"
                print_ok "Destination updated"
            fi
            
            local use_gmail
            use_gmail=$(get_ssm_value "use_gmail_smtp")
            
            if [ "$use_gmail" = "true" ]; then
                echo ""
                print_inf "Gmail SMTP settings:"
                
                echo -n "    Gmail Address (usually same as Sender): "
                read -r gmail_sender
                if [ -n "$gmail_sender" ]; then
                    set_ssm_value "gmail_sender" "$gmail_sender"
                    print_ok "Gmail sender updated"
                fi
                
                echo -n "    Gmail App Password: "
                read -r gmail_pass
                if [ -n "$gmail_pass" ]; then
                    set_ssm_value "gmail_app_password" "$gmail_pass" "SecureString"
                    print_ok "Gmail app password updated"
                fi
            fi
            ;;
        *)
            print_err "Usage: ./manage.sh email <method|configure>"
            ;;
    esac
}

# =============================================================================
# Command: deploy
# =============================================================================

cmd_deploy() {
    print_section "Deploy Infrastructure" "🚀"
    
    local terraform_dir="$(dirname "$0")/../infra"
    
    if [ ! -d "$terraform_dir" ]; then
        print_err "Terraform directory not found at $terraform_dir"
        return
    fi
    
    cd "$terraform_dir"
    
    print_inf "Initializing Terraform (reconfigure backend)..."
    terraform init -reconfigure
    
    print_inf "Planning deployment..."
    terraform plan -out=tfplan
    
    if confirm_action "Do you want to apply this plan?"; then
        print_inf "Applying changes..."
        terraform apply "tfplan"
        print_ok "Deployment complete!"
        
        # Reminder
        echo ""
        print_inf "Remember to configure your application if this is a fresh deploy:"
        echo -e "  ${CYAN}./manage.sh apikeys${NC}"
        echo -e "  ${CYAN}./manage.sh email configure${NC}"
        echo -e "  ${CYAN}./manage.sh channels add <ID>${NC}"
    else
        print_inf "Deployment cancelled."
    fi
    
    [ -f "tfplan" ] && rm "tfplan"
    cd - >/dev/null
}

# =============================================================================
# Command: process (video pipeline — merged from vidscribe.sh)
# =============================================================================

cmd_process() {
    local url1="${1:-}"

    if [ -z "$url1" ]; then
        print_err "Usage: ./manage.sh process <URL1> [URL2...]"
        return
    fi

    print_section "Video Processing Pipeline" "🚀"

    # Collect video IDs
    local video_ids=()
    local urls=("$url1")
    [ -n "${2:-}" ] && urls+=("$2")

    for u in "${urls[@]}"; do
        video_ids+=("$(extract_video_id "$u")")
    done
    print_inf "Video IDs: ${video_ids[*]}"

    # 1. Check SQS queue
    echo ""
    echo -e "    ${YELLOW}🔍 ${WHITE}Checking AWS Resources${NC}"

    local queue_url
    queue_url=$(aws sqs get-queue-url --queue-name "$QUEUE_NAME" --output json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['QueueUrl'])" 2>/dev/null || echo "")
    if [ -z "$queue_url" ]; then
        print_err "SQS queue not found. Is the infrastructure deployed?"
        print_inf "Run: ./manage.sh deploy"
        return
    fi
    print_ok "Queue: $QUEUE_NAME"

    local start_time
    start_time=$(python3 -c "import time; print(int(time.time()*1000))")

    # 2. Inject videos
    echo ""
    echo -e "    ${YELLOW}💉 ${WHITE}Injecting ${#video_ids[@]} video(s) into queue${NC}"

    for vid in "${video_ids[@]}"; do
        local body
        body=$(python3 -c "
import json, datetime
print(json.dumps({
    'video_id': '$vid',
    'title': 'Manual: $vid',
    'channel_id': 'MANUAL',
    'channel_title': 'Manual Trigger',
    'published_at': datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
}))")
        aws sqs send-message --queue-url "$queue_url" --message-body "$body" --no-cli-pager >/dev/null 2>&1 || { print_err "Failed to inject $vid"; continue; }
        print_inf "→ $vid"
    done
    print_ok "All videos queued"

    # 3. Monitor processing
    local wait_timeout=300
    echo ""
    echo -e "    ${YELLOW}⏳ ${WHITE}Waiting for processing (max ${wait_timeout}s)${NC}"

    local pending=("${video_ids[@]}")
    local failed=()
    local elapsed=0
    local poll_interval=5
    local processor_log_group="${LOG_GROUPS[processor]}"

    while [ ${#pending[@]} -gt 0 ] && [ $elapsed -lt $wait_timeout ]; do
        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))

        local log_output
        log_output=$(aws logs filter-log-events \
            --log-group-name "$processor_log_group" \
            --start-time "$start_time" \
            --output json 2>/dev/null || echo "")

        if [ -n "$log_output" ]; then
            local new_pending=()
            for vid in "${pending[@]}"; do
                if echo "$log_output" | grep -q "Successfully processed video: $vid"; then
                    print_ok "Processed: $vid"
                elif echo "$log_output" | grep -qi "error.*$vid\|failed.*$vid"; then
                    print_video_failure_diagnostics "$vid" "$start_time"
                    failed+=("$vid")
                else
                    new_pending+=("$vid")
                fi
            done
            pending=("${new_pending[@]}")
        fi

        # Fallback to DynamoDB status to avoid false 300s waits when processor
        # completes with non-success logs (e.g. FAILED/PERMANENTLY_FAILED).
        local after_status=()
        for vid in "${pending[@]}"; do
            local status
            status=$(get_video_processing_status "$vid")
            if [ "$status" = "PROCESSED" ]; then
                print_ok "Processed: $vid"
            elif [ "$status" = "FAILED" ] || [ "$status" = "PERMANENTLY_FAILED" ]; then
                print_video_failure_diagnostics "$vid" "$start_time" "$status"
                failed+=("$vid")
            else
                after_status+=("$vid")
            fi
        done
        pending=("${after_status[@]}")

        echo -n "."
    done

    echo ""
    if [ ${#pending[@]} -gt 0 ]; then
        print_warn "Timeout! Still pending: ${pending[*]}"
        print_inf "Videos may still be processing. Check: ./manage.sh logs processor"
    elif [ ${#failed[@]} -gt 0 ]; then
        print_warn "Completed with failures: ${failed[*]}"
    else
        print_ok "All videos processed!"
    fi

    # 4. Send newsletter
    echo ""
    echo -e "    ${YELLOW}📧 ${WHITE}Sending Newsletter${NC}"

    local tmp_file
    tmp_file=$(mktemp)
    aws lambda invoke \
        --function-name "$LAMBDA_NEWSLETTER" \
        --cli-binary-format raw-in-base64-out \
        "$tmp_file" \
        --no-cli-pager >/dev/null 2>&1

    if [ -f "$tmp_file" ]; then
        local status_code
        status_code=$(cat "$tmp_file" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('statusCode',0))" 2>/dev/null || echo "0")
        if [ "$status_code" = "200" ]; then
            print_ok "Newsletter sent!"
            local summaries
            summaries=$(cat "$tmp_file" | python3 -c "import sys,json; b=json.loads(json.load(sys.stdin)['body']); print(b.get('summaries_count','?'))" 2>/dev/null || echo "?")
            print_row "Summaries" "$summaries" "$CYAN"
        else
            local error_msg
            error_msg=$(cat "$tmp_file" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('errorMessage',d.get('body','unknown error')))" 2>/dev/null || echo "unknown error")
            print_err "Newsletter error: $error_msg"
        fi
        rm -f "$tmp_file"
    fi

    echo ""
    print_ok "WORKFLOW COMPLETE"
}


case "${COMMAND:-help}" in
    deploy)     cmd_deploy ;;
    channels)   cmd_channels "$SUBCOMMAND" "$ARGUMENT" ;;
    process)    cmd_process "$SUBCOMMAND" "$ARGUMENT" ;;
    newsletter) cmd_newsletter "$SUBCOMMAND" "$ARGUMENT" ;;
    errors)     cmd_errors ;;
    logs)       cmd_logs "$SUBCOMMAND" ;;
    apikeys)    cmd_apikeys ;;
    info)       cmd_info ;;
    cleanup)    cmd_cleanup "$SUBCOMMAND" ;;
    retry)      cmd_retry ;;
    email)      cmd_email "$SUBCOMMAND" "$ARGUMENT" ;;
    help)       cmd_help ;;
    *)
        print_err "Unknown command: $COMMAND"
        echo ""
        print_inf "Run './manage.sh help' for usage information"
        ;;
esac

echo ""
