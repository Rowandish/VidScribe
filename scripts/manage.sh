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

            if [ -n "$arg" ]; then
                print_inf "Processing video and sending test newsletter..."
                bash "$(dirname "$0")/vidscribe.sh" --test-newsletter "$arg"
            else
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
                    local status
                    status=$(cat "$tmp_file" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('statusCode', 0))" 2>/dev/null || echo "0")
                    rm -f "$tmp_file"
                    if [ "$status" = "200" ]; then
                        print_ok "Test newsletter sent successfully"
                    else
                        print_err "Newsletter invocation failed (status: $status)"
                    fi
                fi
            fi
            ;;
        *)
            print_err "Usage: ./manage.sh newsletter <frequency|test> [value]"
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

    # Channels
    local raw
    raw=$(get_ssm_value "youtube_channels")
    local ch_count
    ch_count=$(echo "${raw:-[]}" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
    print_row "Channels" "$ch_count monitored" "$CYAN"

    # Newsletter schedule
    local rule
    rule=$(aws events describe-rule --name "${LAMBDA_NEWSLETTER}-schedule" --output json 2>/dev/null || echo "")
    if [ -n "$rule" ]; then
        local sched state friendly
        sched=$(echo "$rule" | python3 -c "import sys,json; print(json.load(sys.stdin)['ScheduleExpression'])")
        state=$(echo "$rule" | python3 -c "import sys,json; print(json.load(sys.stdin)['State'])")

        case "$sched" in
            "rate(1 day)")  friendly="Daily" ;;
            "rate(7 days)") friendly="Weekly" ;;
            *"1 * ? *"*)    friendly="Monthly" ;;
            *)              friendly="$sched" ;;
        esac
        print_row "Newsletter" "$friendly ($state)" "$CYAN"
    else
        print_row "Newsletter" "Could not read schedule" "$YELLOW"
    fi

    # Email
    local sender dest use_gmail email_method
    sender=$(get_ssm_value "sender_email")
    dest=$(get_ssm_value "destination_email")
    use_gmail=$(get_ssm_value "use_gmail_smtp")
    email_method="Amazon SES"
    [ "$use_gmail" = "true" ] && email_method="Gmail SMTP"

    print_row "Email method" "$email_method" "$CYAN"
    print_row "Sender" "${sender:-Not set}" "$WHITE"
    print_row "Destination" "${dest:-Not set}" "$WHITE"

    # LLM
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

    # API Keys
    local yt_key llm_key yt_status llm_status
    yt_key=$(get_ssm_value "youtube_api_key" "true")
    llm_key=$(get_ssm_value "llm_api_key" "true")
    yt_status="❌ Not set"
    [ -n "$yt_key" ] && [ "$yt_key" != "PLACEHOLDER_REPLACE_ME" ] && yt_status="✅ Configured"
    llm_status="❌ Not set"
    [ -n "$llm_key" ] && [ "$llm_key" != "PLACEHOLDER_REPLACE_ME" ] && llm_status="✅ Configured"
    print_row "YouTube API key" "$yt_status"
    print_row "LLM API key" "$llm_status"

    # Proxy
    local ws_user proxy_status
    ws_user=$(get_ssm_value "webshare_username")
    proxy_status="None"
    [ -n "$ws_user" ] && [ "$ws_user" != "PLACEHOLDER" ] && proxy_status="✅ Webshare ($ws_user)"
    print_row "Proxy" "$proxy_status"

    # DynamoDB stats
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

    # DLQ
    local queue_url dlq_count dlq_color
    queue_url=$(aws sqs get-queue-url --queue-name "$DLQ_NAME" --output json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['QueueUrl'])" 2>/dev/null || echo "")
    if [ -n "$queue_url" ]; then
        dlq_count=$(aws sqs get-queue-attributes --queue-url "$queue_url" --attribute-names ApproximateNumberOfMessages --output json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['Attributes']['ApproximateNumberOfMessages'])" 2>/dev/null || echo "?")
        dlq_color="$GREEN"
        [ "$dlq_count" != "0" ] && dlq_color="$RED"
        print_row "DLQ messages" "$dlq_count" "$dlq_color"
    fi

    # Lambda functions
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
        fi
    done
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
        "channels list:List monitored channels with names"
        "channels add <ID>:Add a YouTube channel by ID"
        "channels remove <ID>:Remove a channel by ID"
        "channels clear:Remove all monitored channels"
        "newsletter frequency <f>:Set frequency: daily, weekly, monthly"
        "newsletter test [URL]:Send a test newsletter"
        "errors:Show failed videos, DLQ, Lambda errors"
        "logs <function>:Tail CloudWatch logs (poller/processor/...)"
        "apikeys update:Interactive API key update wizard"
        "info:Full system status dashboard"
        "cleanup run:Manually trigger DynamoDB cleanup"
        "cleanup status:Show permanently failed record count"
        "retry list:Show videos awaiting transcript retry"
        "help:Show this help message"
    )

    for entry in "${help_cmds[@]}"; do
        local cmd="${entry%%:*}"
        local desc="${entry#*:}"
        printf "    ${CYAN}%-28s${NC}${GRAY}%s${NC}\n" "$cmd" "$desc"
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
    echo -e "    ${DARK_GRAY}./manage.sh newsletter frequency weekly${NC}"
    echo -e "    ${DARK_GRAY}./manage.sh logs processor --lines 100${NC}"
    echo -e "    ${DARK_GRAY}./manage.sh errors --days-back 14${NC}"
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

case "${COMMAND:-help}" in
    channels)   cmd_channels "$SUBCOMMAND" "$ARGUMENT" ;;
    newsletter) cmd_newsletter "$SUBCOMMAND" "$ARGUMENT" ;;
    errors)     cmd_errors ;;
    logs)       cmd_logs "$SUBCOMMAND" ;;
    apikeys)    cmd_apikeys ;;
    info)       cmd_info ;;
    cleanup)    cmd_cleanup "$SUBCOMMAND" ;;
    retry)      cmd_retry ;;
    help)       cmd_help ;;
    *)
        print_err "Unknown command: $COMMAND"
        echo ""
        print_inf "Run './manage.sh help' for usage information"
        ;;
esac

echo ""
