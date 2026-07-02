#!/bin/sh

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/task_sync.conf"

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi

# Get current system info early so config can use per-device overrides.
computer_name=$(hostname)
username=$(whoami)
current_system="$username@$computer_name"

current_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

lookup_device_value() {
    table="$1"
    key="$2"

    printf "%s\n" "$table" | while IFS= read -r line; do
        case "$line" in
            ""|\#*) continue ;;
        esac

        row_key=${line%%=*}
        row_value=${line#*=}
        if [ "$row_key" = "$key" ]; then
            printf "%s\n" "$row_value"
            break
        fi
    done
}

lookup_device_path() {
    table="$1"
    value=$(lookup_device_value "$table" "$DEVICE_CONFIG_KEY")
    if [ -z "$value" ] && [ "$DEVICE_CONFIG_KEY" != "$current_system" ]; then
        value=$(lookup_device_value "$table" "$current_system")
    fi
    printf "%s\n" "$value"
}

path_from_script_dir() {
    path="$1"
    case "$path" in
        "~") printf "%s\n" "$HOME" ;;
        "~/"*) printf "%s\n" "$HOME/${path#~/}" ;;
        ""|/*) printf "%s\n" "$path" ;;
        *) printf "%s\n" "$SCRIPT_DIR/$path" ;;
    esac
}

device_config_alias=$(lookup_device_value "$DEVICE_CONFIG_KEYS" "$computer_name")
if [ -z "$device_config_alias" ]; then
    device_config_alias=$(lookup_device_value "$DEVICE_CONFIG_KEYS" "$current_system")
fi
DEVICE_CONFIG_KEY="${DEVICE_CONFIG_KEY:-${device_config_alias:-$computer_name}}"

TASK_BIN="${TASK_BIN:-task}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
device_nautical_core_path=$(lookup_device_path "$DEVICE_NAUTICAL_CORE_PATHS")
NAUTICAL_CORE_PATH="${device_nautical_core_path:-${NAUTICAL_CORE_PATH:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
NAUTICAL_CORE_PATH=$(path_from_script_dir "$NAUTICAL_CORE_PATH")
RUN_NAUTICAL_CHAIN_REPAIR="${RUN_NAUTICAL_CHAIN_REPAIR:-0}"
RUN_NAUTICAL_RECONCILE="${RUN_NAUTICAL_RECONCILE:-0}"
NAUTICAL_CHAIN_REPAIR_APPLY="${NAUTICAL_CHAIN_REPAIR_APPLY:-0}"
NAUTICAL_RECONCILE_APPLY="${NAUTICAL_RECONCILE_APPLY:-0}"
RUN_NAUTICAL_ON_NO_SYNC="${RUN_NAUTICAL_ON_NO_SYNC:-0}"
SKIP_CONNECTIVITY_CHECK="${SKIP_CONNECTIVITY_CHECK:-0}"

resolve_nautical_base() {
    path="$1"
    if [ -d "$path/nautical_core" ]; then
        cd "$path" 2>/dev/null && pwd
        return
    fi
    if [ -f "$path/__init__.py" ] && [ "$(basename "$path")" = "nautical_core" ]; then
        cd "$(dirname "$path")" 2>/dev/null && pwd
        return
    fi
    printf "%s\n" "$path"
}

NAUTICAL_BASE="$(resolve_nautical_base "$NAUTICAL_CORE_PATH")"
device_nautical_tools_dir=$(lookup_device_path "$DEVICE_NAUTICAL_TOOLS_DIRS")
NAUTICAL_TOOLS_DIR="${device_nautical_tools_dir:-${NAUTICAL_TOOLS_DIR:-$NAUTICAL_BASE/nautical_core/tools}}"
NAUTICAL_TOOLS_DIR=$(path_from_script_dir "$NAUTICAL_TOOLS_DIR")

device_lock_dir=$(lookup_device_path "$DEVICE_LOCK_DIRS")
LOCK_DIR="${device_lock_dir:-${LOCK_DIR:-$SCRIPT_DIR/.task_sync.lock}}"
LOCK_DIR=$(path_from_script_dir "$LOCK_DIR")
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "❌ Another task sync run is already active: $LOCK_DIR"
    exit 1
fi
cleanup_lock() {
    rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup_lock EXIT
trap 'cleanup_lock; exit 130' INT
trap 'cleanup_lock; exit 143' TERM

# ──────────────────────────────────────────────────────────────────────────
# Per-device logging: each device writes to its own file to avoid conflicts
# DEVICE_ID:
#   - default: "$USER@$HOSTNAME"
#   - override: set LOG_DEVICE_ID="phone" (or any label) in task_sync.conf
# Sanitization ensures a safe filename across OS/filesystems.
# Logs live under SCRIPT_DIR/logs/
# ──────────────────────────────────────────────────────────────────────────

# Decide device ID (env override wins)
DEVICE_ID="${LOG_DEVICE_ID:-$current_system}"
# Sanitize to safe filename: keep letters, digits, dot, underscore, dash
DEVICE_ID_SAFE=$(printf "%s" "$DEVICE_ID" | tr -c 'A-Za-z0-9._-' '-')

# Log dir and per-device log file
device_log_dir=$(lookup_device_path "$DEVICE_LOG_DIRS")
LOG_DIR="${device_log_dir:-${LOG_DIR:-$SCRIPT_DIR/logs}}"
LOG_DIR=$(path_from_script_dir "$LOG_DIR")
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/task_sync_${DEVICE_ID_SAFE}.log"

# Sync state file (shared state is intentional; only logs are per-device)
SYNC_STATE_FILE="$SCRIPT_DIR/last_sync_state"

# Max per-log size (100KB)
MAX_LOG_SIZE="${MAX_LOG_SIZE:-102400}"  # 100KB in bytes

# Variables for final summary log
SCRIPT_RESULT=""
SYNC_ACTION=""
ERROR_DETAILS=""
CHANGES_INFO=""

# Function to rotate log file if it exceeds maximum size
rotate_log_if_needed() {
    if [ -f "$LOG_FILE" ]; then
        log_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo "0")
        if [ "$log_size" -gt "$MAX_LOG_SIZE" ]; then
            echo "Log file size ($log_size bytes) exceeds maximum ($MAX_LOG_SIZE bytes). Rotating..."
            mv "$LOG_FILE" "${LOG_FILE}.bak"
            : > "$LOG_FILE"
            # Log rotation line is device-scoped as well
            rotate_timestamp=$(current_timestamp)
            echo "[$rotate_timestamp] [INFO] $current_system - Log rotated (${log_size}B -> 0B), backup: ${LOG_FILE}.bak" >> "$LOG_FILE"
        fi
    fi
}

# Function to write final summary log (only called once at script end)
write_summary_log() {
    summary_status="$1"
    summary_action="$2"
    summary_details="$3"
    summary_timestamp=$(current_timestamp)

    rotate_log_if_needed

    # One-line summary per device
    if [ -n "$summary_details" ]; then
        echo "[$summary_timestamp] [$summary_status] $current_system - $summary_action | $summary_details" >> "$LOG_FILE"
    else
        echo "[$summary_timestamp] [$summary_status] $current_system - $summary_action" >> "$LOG_FILE"
    fi
}

# Function to check internet connectivity (silent operation)
check_internet() {
    if [ "$SKIP_CONNECTIVITY_CHECK" = "1" ]; then
        echo "🌐 Connectivity check skipped by config"
        return 0
    fi

    echo "🌐 Checking internet connectivity..."

    if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        echo "✅ Internet connectivity confirmed (Google DNS reachable)"
        return 0
    fi
    if ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
        echo "✅ Internet connectivity confirmed (Cloudflare DNS reachable)"
        return 0
    fi
    if command -v curl >/dev/null 2>&1; then
        if curl -s --connect-timeout 5 --max-time 10 http://httpbin.org/status/200 >/dev/null 2>&1; then
            echo "✅ Internet connectivity confirmed (HTTP test successful)"
            return 0
        fi
    fi
    if command -v wget >/dev/null 2>&1; then
        if wget -q --spider --timeout=5 --tries=1 http://httpbin.org/status/200 >/dev/null 2>&1; then
            echo "✅ Internet connectivity confirmed (wget test successful)"
            return 0
        fi
    fi

    echo "❌ No internet connectivity detected"
    return 1
}

# Function to update sync state file
update_sync_state() {
    sync_type="$1"  # "WITH_CHANGES" or "NO_CHANGES"
    state_timestamp=$(current_timestamp)
    state_tmp="${SYNC_STATE_FILE}.tmp.$$"

    {
        echo "LAST_SYNC_TIME=$state_timestamp"
        echo "LAST_SYNC_SYSTEM=$current_system"
        echo "LAST_SYNC_TYPE=$sync_type"
    } > "$state_tmp" || return 1

    mv "$state_tmp" "$SYNC_STATE_FILE"
}

# Function to mark that current system has synced the latest changes
mark_system_synced() {
    if [ -f "$SYNC_STATE_FILE" ]; then
        SYNCED_SYSTEMS=$(grep "^SYNCED_SYSTEMS=" "$SYNC_STATE_FILE" 2>/dev/null | cut -d'=' -f2-)

        if ! system_is_synced "$SYNCED_SYSTEMS" "$current_system"; then
            if [ -n "$SYNCED_SYSTEMS" ]; then
                SYNCED_SYSTEMS="$SYNCED_SYSTEMS,$current_system"
            else
                SYNCED_SYSTEMS="$current_system"
            fi

            state_tmp="${SYNC_STATE_FILE}.tmp.$$"
            grep -v "^SYNCED_SYSTEMS=" "$SYNC_STATE_FILE" > "$state_tmp" 2>/dev/null || true
            echo "SYNCED_SYSTEMS=$SYNCED_SYSTEMS" >> "$state_tmp" || return 1
            mv "$state_tmp" "$SYNC_STATE_FILE"
        fi
    fi
}

system_is_synced() {
    systems_csv="$1"
    system_name="$2"
    case ",$systems_csv," in
        *,"$system_name",*) return 0 ;;
        *) return 1 ;;
    esac
}

# Function to get pending task count
get_task_count() {
    "$TASK_BIN" status:pending count 2>/dev/null || echo "0"
}

config_true() {
    case "$1" in
        1|yes|true|on|YES|TRUE|ON) return 0 ;;
        *) return 1 ;;
    esac
}

run_tool() {
    label="$1"
    script_path="$2"
    apply_flag="$3"

    if [ ! -f "$script_path" ]; then
        echo "⚠️  Nautical $label skipped: missing $script_path"
        return 0
    fi

    echo "🧭 Nautical $label..."
    if config_true "$apply_flag"; then
        NAUTICAL_CORE_PATH="$NAUTICAL_CORE_PATH" "$PYTHON_BIN" "$script_path" --task-bin "$TASK_BIN" --apply
    else
        NAUTICAL_CORE_PATH="$NAUTICAL_CORE_PATH" "$PYTHON_BIN" "$script_path" --task-bin "$TASK_BIN"
    fi
}

run_nautical_recovery() {
    recovery_status=0

    if config_true "$RUN_NAUTICAL_CHAIN_REPAIR"; then
        if ! run_tool "chain repair" "$NAUTICAL_TOOLS_DIR/nautical_chain_repair.py" "$NAUTICAL_CHAIN_REPAIR_APPLY"; then
            recovery_status=1
        fi
    fi

    if config_true "$RUN_NAUTICAL_RECONCILE"; then
        if ! run_tool "reconcile" "$NAUTICAL_TOOLS_DIR/nautical_reconcile.py" "$NAUTICAL_RECONCILE_APPLY"; then
            recovery_status=1
        fi
    fi

    return "$recovery_status"
}

nautical_recovery_enabled() {
    config_true "$RUN_NAUTICAL_CHAIN_REPAIR" || config_true "$RUN_NAUTICAL_RECONCILE"
}

run_nautical_recovery_and_record() {
    if run_nautical_recovery; then
        NAUTICAL_RECOVERY_RESULT="Nautical recovery ok"
    else
        echo "⚠️  Nautical recovery reported findings or errors"
        NAUTICAL_RECOVERY_RESULT="Nautical recovery needs review"
    fi
}

# Function to perform sync and logging
perform_sync() {
    sync_reason="$1"
    changes_count="$2"
    sync_type="$3"  # "WITH_CHANGES" or "NO_CHANGES"
    pre_sync_nautical_info=""

    SYNC_ACTION="$sync_reason"

    # Check internet connectivity before syncing
    if ! check_internet; then
        echo "❌ ERROR: Cannot sync - no internet connectivity"
        SCRIPT_RESULT="ERROR"
        ERROR_DETAILS="No internet connectivity"

        if [ "$sync_type" = "WITH_CHANGES" ]; then
            echo "⚠️  WARNING: You have $changes_count local changes that cannot be synced offline"
            echo "📡 Please run this script again when internet connectivity is restored"
            CHANGES_INFO="$changes_count local changes pending"
        fi

        return 1
    fi

    if [ "$sync_type" = "WITH_CHANGES" ] && nautical_recovery_enabled; then
        echo "🧭 Running Nautical recovery before sync so spawned tasks are included..."
        run_nautical_recovery_and_record
        pre_sync_nautical_info=", $NAUTICAL_RECOVERY_RESULT"
    fi

    # Prepare changes info for summary
    if [ -n "$changes_count" ]; then
        echo "🔄 $sync_reason - Syncing $changes_count tasks"
        CHANGES_INFO="$changes_count tasks synced"
    else
        echo "🔄 $sync_reason - Running sync to pull remote changes"
        CHANGES_INFO="pulled remote changes"
    fi

    # Get task count before sync
    echo "📋 Before sync - checking pending task count:"
    task_count_before=$(get_task_count)
    echo "  📊 Pending tasks: $task_count_before"

    echo "⏳ Executing task sync..."
    "$TASK_BIN" sync
    sync_exit_code=$?

    # Get task count after sync
    echo "📋 After sync - checking pending task count:"
    task_count_after=$(get_task_count)
    echo "  📊 Pending tasks: $task_count_after"
    
    # Calculate delta
    task_delta=$((task_count_after - task_count_before))
    if [ $task_delta -gt 0 ]; then
        echo "  📈 Task delta: +$task_delta (tasks added)"
    elif [ $task_delta -lt 0 ]; then
        echo "  📉 Task delta: $task_delta (tasks removed)"
    else
        echo "  ➖ Task delta: 0 (no change)"
    fi
    
    echo "🔍 Sync exit code: $sync_exit_code"

    if [ $sync_exit_code -ne 0 ]; then
        echo "⚠️  WARNING: Sync command failed with exit code $sync_exit_code"
        echo "🌐 This might be due to network issues or server problems"

        SCRIPT_RESULT="ERROR"
        ERROR_DETAILS="Sync failed (exit code: $sync_exit_code)"
        return 1
    fi

    # Update changes info to include task counts and delta
    if [ -n "$changes_count" ]; then
        CHANGES_INFO="$changes_count tasks synced, count: $task_count_before->$task_count_after (Δ$task_delta)"
    else
        CHANGES_INFO="pulled remote changes, count: $task_count_before->$task_count_after (Δ$task_delta)"
    fi
    CHANGES_INFO="$CHANGES_INFO$pre_sync_nautical_info"

    # Handle state file updates
    if [ "$sync_type" = "WITH_CHANGES" ]; then
        update_sync_state "$sync_type"
        mark_system_synced
    else
        post_sync_output=$("$TASK_BIN" due:today list 2>&1)
        post_sync_last_line=$(echo "$post_sync_output" | tail -n 1)

        if echo "$post_sync_last_line" | grep -q "Sync required."; then
            echo "⚠️  WARNING: Local changes still exist after sync!"
            echo "📊 Post-sync status: $post_sync_last_line"
            echo "🚫 Not marking system as synced due to remaining local changes"
            CHANGES_INFO="$CHANGES_INFO (local changes remain)"
        else
            mark_system_synced
        fi
    fi

    if [ "$sync_type" = "NO_CHANGES" ] && nautical_recovery_enabled; then
        echo "🧭 Running Nautical recovery after pulling remote changes..."
        run_nautical_recovery_and_record
        CHANGES_INFO="$CHANGES_INFO, $NAUTICAL_RECOVERY_RESULT"
    fi

    SCRIPT_RESULT="SUCCESS"
    return 0
}

# Run the task command and capture output first
echo "🔍 Checking current task status..."
task_output=$("$TASK_BIN" due:today list 2>&1)
last_line=$(echo "$task_output" | tail -n 1)

# Check if there are local changes
has_local_changes=0
changes_count=""
if echo "$last_line" | grep -q "Sync required."; then
    has_local_changes=1
    changes_count=$(echo "$last_line" | grep -o '[0-9][0-9]*' | head -n 1)
    echo "📝 Local changes detected: $changes_count tasks need syncing"
else
    echo "📋 No local changes detected"
fi

# Check if sync state file exists and read it
need_sync_for_different_system=0
if [ -f "$SYNC_STATE_FILE" ]; then
    LAST_SYNC_TIME=$(grep "^LAST_SYNC_TIME=" "$SYNC_STATE_FILE" | cut -d'=' -f2-)
    LAST_SYNC_SYSTEM=$(grep "^LAST_SYNC_SYSTEM=" "$SYNC_STATE_FILE" | cut -d'=' -f2-)
    LAST_SYNC_TYPE=$(grep "^LAST_SYNC_TYPE=" "$SYNC_STATE_FILE" | cut -d'=' -f2-)
    SYNCED_SYSTEMS=$(grep "^SYNCED_SYSTEMS=" "$SYNC_STATE_FILE" | cut -d'=' -f2-)

    if [ "$LAST_SYNC_TYPE" = "WITH_CHANGES" ] && ! system_is_synced "$SYNCED_SYSTEMS" "$current_system"; then
        echo "🔄 Changes available from $LAST_SYNC_SYSTEM (at $LAST_SYNC_TIME)"
        echo "📥 Current system $current_system has not synced these changes yet"
        need_sync_for_different_system=1
    elif [ "$LAST_SYNC_TYPE" = "WITH_CHANGES" ] && system_is_synced "$SYNCED_SYSTEMS" "$current_system"; then
        echo "✅ Current system has already synced the latest changes from $LAST_SYNC_SYSTEM"
    fi
else
    echo "🆕 No sync state file found - this appears to be the first run"
    need_sync_for_different_system=1
fi

# Debug output
echo "🔧 Debug Information:"
echo "   📊 Local changes: $([ $has_local_changes -eq 1 ] && echo "$changes_count tasks" || echo "none")"
echo "   📋 Current pending tasks: $(get_task_count)"
if [ -f "$SYNC_STATE_FILE" ]; then
    echo "   💻 Last sync system: $LAST_SYNC_SYSTEM"
    echo "   🏠 Current system: $current_system"
    echo "   📅 Last sync type: $LAST_SYNC_TYPE"
    echo "   🔗 Systems match: $([ "$LAST_SYNC_SYSTEM" = "$current_system" ] && echo "YES" || echo "NO")"
    echo "   📝 Last sync had changes: $([ "$LAST_SYNC_TYPE" = "WITH_CHANGES" ] && echo " YES" || echo " NO")"
fi
echo "   🔄 Need remote sync: $([ $need_sync_for_different_system -eq 1 ] && echo "YES" || echo "NO")"

# Determine sync action
if [ $has_local_changes -eq 1 ]; then
    echo "🚀 Decision: Syncing due to local changes"
    if perform_sync "Local changes detected" "$changes_count" "WITH_CHANGES"; then
        echo "🎉 Sync completed successfully"
        write_summary_log "$SCRIPT_RESULT" "SYNC_LOCAL_CHANGES" "$CHANGES_INFO"
    else
        echo "💥 Sync failed - please check connectivity and try again"
        write_summary_log "$SCRIPT_RESULT" "SYNC_LOCAL_CHANGES_FAILED" "$ERROR_DETAILS | $CHANGES_INFO"
        exit 1
    fi
elif [ $need_sync_for_different_system -eq 1 ]; then
    echo "🚀 Decision: Syncing to pull remote changes"
    if perform_sync "Pulling remote changes" "" "NO_CHANGES"; then
        echo "🎉 Sync completed successfully"
        write_summary_log "$SCRIPT_RESULT" "SYNC_REMOTE_CHANGES" "$CHANGES_INFO"
    else
        echo "💥 Sync failed - please check connectivity and try again"
        write_summary_log "$SCRIPT_RESULT" "SYNC_REMOTE_CHANGES_FAILED" "$ERROR_DETAILS"
        exit 1
    fi
else
    echo "✅ Decision: No sync needed"
    echo "🏠 No sync required - system is up-to-date"
    current_task_count=$(get_task_count)
    recovery_info=""
    if config_true "$RUN_NAUTICAL_ON_NO_SYNC"; then
        if run_nautical_recovery; then
            recovery_info=", Nautical recovery ok"
        else
            echo "⚠️  Nautical recovery reported findings or errors"
            recovery_info=", Nautical recovery needs review"
        fi
    fi
    if [ -f "$SYNC_STATE_FILE" ]; then
        echo "📅 Last sync: $LAST_SYNC_SYSTEM at $LAST_SYNC_TIME ($LAST_SYNC_TYPE)"
        write_summary_log "INFO" "NO_SYNC_NEEDED" "up-to-date, $current_task_count pending tasks, last sync: $LAST_SYNC_SYSTEM at $LAST_SYNC_TIME$recovery_info"
    else
        write_summary_log "INFO" "NO_SYNC_NEEDED" "up-to-date, $current_task_count pending tasks, no previous sync state$recovery_info"
    fi
fi
