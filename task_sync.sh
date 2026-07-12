#!/bin/sh

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${TASK_SYNC_CONFIG:-$SCRIPT_DIR/task_sync.conf}"

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi

# Get current system info early so config can use per-device overrides.
computer_name=$(hostname)
username=$(whoami)
current_system="$username@$computer_name"

# Stable labels used for local runtime files and per-device logs.
DEVICE_ID="${LOG_DEVICE_ID:-$current_system}"
DEVICE_ID_SAFE=$(printf "%s" "$DEVICE_ID" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-')

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
runtime_dir="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
LOCK_DIR="${device_lock_dir:-${LOCK_DIR:-$runtime_dir/taskwarrior-sync-helper-${DEVICE_ID_SAFE}.lock}}"
LOCK_DIR=$(path_from_script_dir "$LOCK_DIR")

cleanup_lock() {
    lock_owner=$(sed -n '1p' "$LOCK_DIR/pid" 2>/dev/null)
    if [ "$lock_owner" = "$$" ]; then
        rm -f "$LOCK_DIR/pid"
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
}

acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        if printf '%s\n' "$$" > "$LOCK_DIR/pid"; then
            return 0
        fi
        rmdir "$LOCK_DIR" 2>/dev/null || true
        echo "❌ Unable to initialize task sync lock: $LOCK_DIR"
        return 1
    fi

    if [ ! -d "$LOCK_DIR" ]; then
        echo "❌ Unable to create task sync lock: $LOCK_DIR"
        return 1
    fi

    lock_owner=$(sed -n '1p' "$LOCK_DIR/pid" 2>/dev/null)
    case "$lock_owner" in
        ''|*[!0-9]*) lock_owner="" ;;
    esac

    if [ -n "$lock_owner" ] && kill -0 "$lock_owner" 2>/dev/null; then
        echo "❌ Another task sync run is already active (PID $lock_owner): $LOCK_DIR"
        return 1
    fi

    stale_lock="${LOCK_DIR}.stale.$$"
    if ! mv "$LOCK_DIR" "$stale_lock" 2>/dev/null; then
        echo "❌ Unable to inspect existing task sync lock: $LOCK_DIR"
        return 1
    fi
    rm -f "$stale_lock/pid"
    if ! rmdir "$stale_lock" 2>/dev/null; then
        mv "$stale_lock" "$LOCK_DIR" 2>/dev/null || true
        echo "❌ Existing lock contains unexpected files: $LOCK_DIR"
        return 1
    fi

    if ! mkdir "$LOCK_DIR" 2>/dev/null || ! printf '%s\n' "$$" > "$LOCK_DIR/pid"; then
        rmdir "$LOCK_DIR" 2>/dev/null || true
        echo "❌ Unable to acquire task sync lock: $LOCK_DIR"
        return 1
    fi

    echo "♻️  Recovered stale task sync lock: $LOCK_DIR"
}

if ! acquire_lock; then
    exit 1
fi

trap cleanup_lock 0
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

# Log dir and per-device log file
device_log_dir=$(lookup_device_path "$DEVICE_LOG_DIRS")
LOG_DIR="${device_log_dir:-${LOG_DIR:-$SCRIPT_DIR/logs}}"
LOG_DIR=$(path_from_script_dir "$LOG_DIR")
if ! mkdir -p "$LOG_DIR"; then
    echo "❌ Unable to create task sync log directory: $LOG_DIR"
    exit 1
fi
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
    if [ ! -f "$SYNC_STATE_FILE" ]; then
        return 1
    fi

    SYNCED_SYSTEMS=$(grep "^SYNCED_SYSTEMS=" "$SYNC_STATE_FILE" 2>/dev/null | cut -d'=' -f2-)

    if ! system_is_synced "$SYNCED_SYSTEMS" "$current_system"; then
        if [ -n "$SYNCED_SYSTEMS" ]; then
            SYNCED_SYSTEMS="$SYNCED_SYSTEMS,$current_system"
        else
            SYNCED_SYSTEMS="$current_system"
        fi

        state_tmp="${SYNC_STATE_FILE}.tmp.$$"
        awk '!/^SYNCED_SYSTEMS=/' "$SYNC_STATE_FILE" > "$state_tmp" 2>/dev/null || return 1
        echo "SYNCED_SYSTEMS=$SYNCED_SYSTEMS" >> "$state_tmp" || return 1
        mv "$state_tmp" "$SYNC_STATE_FILE" || return 1
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

# Query Taskwarrior using output intended for automation. The result is exposed
# through TASK_COUNT_RESULT so callers can distinguish a real zero from failure.
query_task_count() {
    task_count_output=$(LC_ALL=C "$TASK_BIN" rc.hooks=0 rc.verbose=nothing rc.color=off status:pending count 2>&1)
    task_count_status=$?
    if [ "$task_count_status" -ne 0 ]; then
        echo "❌ Taskwarrior count query failed: $task_count_output" >&2
        return 1
    fi

    TASK_COUNT_RESULT=$(printf '%s\n' "$task_count_output" | awk '
        /^[[:space:]]*[0-9]+[[:space:]]*$/ { value = $1 }
        END { if (value != "") print value }
    ')
    case "$TASK_COUNT_RESULT" in
        ''|*[!0-9]*)
            echo "❌ Taskwarrior returned an invalid pending count: $task_count_output" >&2
            return 1
            ;;
    esac
}

get_task_count() {
    query_task_count || return 1
    printf '%s\n' "$TASK_COUNT_RESULT"
}

validate_taskwarrior() {
    if ! command -v "$TASK_BIN" >/dev/null 2>&1; then
        echo "❌ Taskwarrior command not found or not executable: $TASK_BIN"
        return 1
    fi
    if ! "$TASK_BIN" --version >/dev/null 2>&1; then
        echo "❌ Taskwarrior command failed its version check: $TASK_BIN"
        return 1
    fi
    query_task_count
}

# Taskwarrior 3 exposes its local-operation backlog in `task stats`, including
# for local-directory sync where no "Sync required" footnote is emitted.
# Taskwarrior 2 falls back to the reminder, with explicit locale and verbosity
# so user configuration cannot suppress or localize it.
probe_local_changes() {
    LOCAL_CHANGES_COUNT=""

    task_stats_output=$(LC_ALL=C "$TASK_BIN" rc.hooks=0 rc.verbose=nothing rc.color=off stats 2>&1)
    task_stats_status=$?
    if [ "$task_stats_status" -eq 0 ]; then
        sync_backlog=$(printf '%s\n' "$task_stats_output" | awk '
            /^Sync backlog transactions[[:space:]]+[0-9]+[[:space:]]*$/ {
                print $NF
                exit
            }
        ')
        if [ -n "$sync_backlog" ]; then
            if [ "$sync_backlog" -gt 0 ]; then
                LOCAL_CHANGES_COUNT="$sync_backlog"
                return 0
            fi
            return 1
        fi
    fi

    task_probe_output=$(LC_ALL=C "$TASK_BIN" rc.hooks=0 rc.verbose=footnote,sync rc.color=off due:today list 2>&1)
    task_probe_status=$?
    sync_reminder=$(printf '%s\n' "$task_probe_output" | awk '
        /local change/ && /Sync required[.]/ { print; exit }
    ')

    if [ -n "$sync_reminder" ]; then
        LOCAL_CHANGES_COUNT=$(printf '%s\n' "$sync_reminder" | awk '
            {
                for (i = 1; i < NF; i++) {
                    if ($i ~ /^[0-9]+$/ && $(i + 1) == "local") {
                        print $i
                        exit
                    }
                }
            }
        ')
        return 0
    fi

    # Taskwarrior reports "No matches" with status 1, so both 0 and 1 are
    # expected for this read-only report. Other statuses are probe failures.
    if [ "$task_probe_status" -ne 0 ] && [ "$task_probe_status" -ne 1 ]; then
        echo "❌ Taskwarrior sync-status probe failed: $task_probe_output" >&2
        return 2
    fi
    return 1
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
        echo "❌ Nautical $label cannot run: missing $script_path"
        return 1
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
        return 0
    else
        echo "⚠️  Nautical recovery reported findings or errors"
        NAUTICAL_RECOVERY_RESULT="Nautical recovery needs review"
        return 1
    fi
}

# Function to perform sync and logging
perform_sync() {
    sync_reason="$1"
    local_operations_count="$2"
    sync_type="$3"  # "WITH_CHANGES" or "NO_CHANGES"
    pre_sync_nautical_info=""

    SYNC_ACTION="$sync_reason"

    if [ "$sync_type" = "WITH_CHANGES" ] && nautical_recovery_enabled; then
        echo "🧭 Running Nautical recovery before sync so spawned tasks are included..."
        if ! run_nautical_recovery_and_record; then
            SCRIPT_RESULT="ERROR"
            ERROR_DETAILS="Pre-sync Nautical recovery failed"
            return 1
        fi
        pre_sync_nautical_info=", $NAUTICAL_RECOVERY_RESULT"
    fi

    # Prepare changes info for summary
    if [ "$sync_type" = "WITH_CHANGES" ] && [ -n "$local_operations_count" ]; then
        echo "🔄 $sync_reason - Syncing $local_operations_count local operations"
        CHANGES_INFO="$local_operations_count local operations synced"
    elif [ "$sync_type" = "WITH_CHANGES" ]; then
        echo "🔄 $sync_reason - Syncing local changes"
        CHANGES_INFO="local changes synced"
    else
        echo "🔄 $sync_reason - Running sync to pull remote changes"
        CHANGES_INFO="pulled remote changes"
    fi

    # Get task count before sync
    echo "📋 Before sync - checking pending task count:"
    if ! task_count_before=$(get_task_count); then
        SCRIPT_RESULT="ERROR"
        ERROR_DETAILS="Unable to query pending tasks before sync"
        return 1
    fi
    echo "  📊 Pending tasks: $task_count_before"

    echo "⏳ Executing task sync..."
    "$TASK_BIN" sync
    sync_exit_code=$?

    echo "🔍 Sync exit code: $sync_exit_code"

    if [ "$sync_exit_code" -ne 0 ]; then
        echo "⚠️  WARNING: Sync command failed with exit code $sync_exit_code"

        SCRIPT_RESULT="ERROR"
        ERROR_DETAILS="Sync failed (exit code: $sync_exit_code)"
        return 1
    fi

    # Get task count after a successful sync.
    echo "📋 After sync - checking pending task count:"
    if ! task_count_after=$(get_task_count); then
        SCRIPT_RESULT="ERROR"
        ERROR_DETAILS="Unable to query pending tasks after sync"
        return 1
    fi
    echo "  📊 Pending tasks: $task_count_after"

    task_delta=$((task_count_after - task_count_before))
    if [ "$task_delta" -gt 0 ]; then
        echo "  📈 Task delta: +$task_delta (tasks added)"
    elif [ "$task_delta" -lt 0 ]; then
        echo "  📉 Task delta: $task_delta (tasks removed)"
    else
        echo "  ➖ Task delta: 0 (no change)"
    fi

    # Update changes info to include task counts and delta
    if [ "$sync_type" = "WITH_CHANGES" ] && [ -n "$local_operations_count" ]; then
        CHANGES_INFO="$local_operations_count local operations synced, count: $task_count_before->$task_count_after (Δ$task_delta)"
    elif [ "$sync_type" = "WITH_CHANGES" ]; then
        CHANGES_INFO="local changes synced, count: $task_count_before->$task_count_after (Δ$task_delta)"
    else
        CHANGES_INFO="pulled remote changes, count: $task_count_before->$task_count_after (Δ$task_delta)"
    fi
    CHANGES_INFO="$CHANGES_INFO$pre_sync_nautical_info"

    if [ "$sync_type" = "NO_CHANGES" ] && nautical_recovery_enabled; then
        echo "🧭 Running Nautical recovery after pulling remote changes..."
        if ! run_nautical_recovery_and_record; then
            SCRIPT_RESULT="ERROR"
            ERROR_DETAILS="Post-sync Nautical recovery failed"
            return 1
        fi
        CHANGES_INFO="$CHANGES_INFO, $NAUTICAL_RECOVERY_RESULT"
    fi

    # Commit shared state only after sync and recovery have succeeded.
    if [ "$sync_type" = "WITH_CHANGES" ]; then
        if ! update_sync_state "$sync_type" || ! mark_system_synced; then
            SCRIPT_RESULT="ERROR"
            ERROR_DETAILS="Unable to update shared sync state"
            return 1
        fi
    else
        probe_local_changes
        post_probe_status=$?
        if [ "$post_probe_status" -eq 0 ]; then
            echo "⚠️  WARNING: Local changes still exist after sync"
            echo "🚫 Not marking system as synced due to remaining local changes"
            CHANGES_INFO="$CHANGES_INFO (local changes remain)"
        elif [ "$post_probe_status" -eq 2 ]; then
            SCRIPT_RESULT="ERROR"
            ERROR_DETAILS="Unable to verify local state after sync"
            return 1
        else
            if [ "$INITIALIZE_SYNC_STATE" -eq 1 ] && ! update_sync_state "NO_CHANGES"; then
                SCRIPT_RESULT="ERROR"
                ERROR_DETAILS="Unable to initialize shared sync state"
                return 1
            fi
            if ! mark_system_synced; then
                SCRIPT_RESULT="ERROR"
                ERROR_DETAILS="Unable to mark system as synced"
                return 1
            fi
        fi
    fi

    SCRIPT_RESULT="SUCCESS"
    return 0
}

# Validate Taskwarrior and probe the local sync reminder.
echo "🔍 Checking current task status..."
if ! validate_taskwarrior; then
    write_summary_log "ERROR" "PREFLIGHT_FAILED" "Taskwarrior is unavailable or its data cannot be queried"
    exit 1
fi
initial_task_count="$TASK_COUNT_RESULT"

has_local_changes=0
local_operations_count=""
probe_local_changes
initial_probe_status=$?
case "$initial_probe_status" in
    0)
        has_local_changes=1
        local_operations_count="$LOCAL_CHANGES_COUNT"
        if [ -n "$local_operations_count" ]; then
            echo "📝 Local changes detected: $local_operations_count local operations need syncing"
        else
            echo "📝 Local changes detected"
        fi
        ;;
    1)
        echo "📋 No local changes detected"
        ;;
    *)
        write_summary_log "ERROR" "PREFLIGHT_FAILED" "Unable to determine local sync status"
        exit 1
        ;;
esac

# Check if sync state file exists and read it
need_sync_for_different_system=0
INITIALIZE_SYNC_STATE=0
if [ -f "$SYNC_STATE_FILE" ]; then
    LAST_SYNC_TIME=$(grep "^LAST_SYNC_TIME=" "$SYNC_STATE_FILE" | cut -d'=' -f2-)
    LAST_SYNC_SYSTEM=$(grep "^LAST_SYNC_SYSTEM=" "$SYNC_STATE_FILE" | cut -d'=' -f2-)
    LAST_SYNC_TYPE=$(grep "^LAST_SYNC_TYPE=" "$SYNC_STATE_FILE" | cut -d'=' -f2-)
    SYNCED_SYSTEMS=$(grep "^SYNCED_SYSTEMS=" "$SYNC_STATE_FILE" | cut -d'=' -f2-)

    state_is_valid=1
    if [ -z "$LAST_SYNC_TIME" ] || [ -z "$LAST_SYNC_SYSTEM" ]; then
        state_is_valid=0
    fi
    case "$LAST_SYNC_TYPE" in
        WITH_CHANGES|NO_CHANGES) ;;
        *) state_is_valid=0 ;;
    esac

    if [ "$state_is_valid" -eq 0 ]; then
        echo "⚠️  Shared sync state is incomplete or invalid; running a conservative sync"
        need_sync_for_different_system=1
        INITIALIZE_SYNC_STATE=1
    elif [ "$LAST_SYNC_TYPE" = "WITH_CHANGES" ] && ! system_is_synced "$SYNCED_SYSTEMS" "$current_system"; then
        echo "🔄 Changes available from $LAST_SYNC_SYSTEM (at $LAST_SYNC_TIME)"
        echo "📥 Current system $current_system has not synced these changes yet"
        need_sync_for_different_system=1
    elif [ "$LAST_SYNC_TYPE" = "WITH_CHANGES" ] && system_is_synced "$SYNCED_SYSTEMS" "$current_system"; then
        echo "✅ Current system has already synced the latest changes from $LAST_SYNC_SYSTEM"
    fi
else
    echo "🆕 No sync state file found - this appears to be the first run"
    need_sync_for_different_system=1
    INITIALIZE_SYNC_STATE=1
fi

# Debug output
echo "🔧 Debug Information:"
echo "   📊 Local changes: $([ "$has_local_changes" -eq 1 ] && { [ -n "$local_operations_count" ] && echo "$local_operations_count operations" || echo "detected"; } || echo "none")"
echo "   📋 Current pending tasks: $initial_task_count"
if [ -f "$SYNC_STATE_FILE" ]; then
    echo "   💻 Last sync system: $LAST_SYNC_SYSTEM"
    echo "   🏠 Current system: $current_system"
    echo "   📅 Last sync type: $LAST_SYNC_TYPE"
    echo "   🔗 Systems match: $([ "$LAST_SYNC_SYSTEM" = "$current_system" ] && echo "YES" || echo "NO")"
    echo "   📝 Last sync had changes: $([ "$LAST_SYNC_TYPE" = "WITH_CHANGES" ] && echo " YES" || echo " NO")"
fi
echo "   🔄 Need remote sync: $([ $need_sync_for_different_system -eq 1 ] && echo "YES" || echo "NO")"

# Determine sync action
if [ "$has_local_changes" -eq 1 ]; then
    echo "🚀 Decision: Syncing due to local changes"
    if perform_sync "Local changes detected" "$local_operations_count" "WITH_CHANGES"; then
        echo "🎉 Sync completed successfully"
        write_summary_log "$SCRIPT_RESULT" "SYNC_LOCAL_CHANGES" "$CHANGES_INFO"
    else
        echo "💥 Sync failed - review the error above and try again"
        write_summary_log "$SCRIPT_RESULT" "SYNC_LOCAL_CHANGES_FAILED" "$ERROR_DETAILS | $CHANGES_INFO"
        exit 1
    fi
elif [ "$need_sync_for_different_system" -eq 1 ]; then
    echo "🚀 Decision: Syncing to pull remote changes"
    if perform_sync "Pulling remote changes" "" "NO_CHANGES"; then
        echo "🎉 Sync completed successfully"
        write_summary_log "$SCRIPT_RESULT" "SYNC_REMOTE_CHANGES" "$CHANGES_INFO"
    else
        echo "💥 Sync failed - review the error above and try again"
        write_summary_log "$SCRIPT_RESULT" "SYNC_REMOTE_CHANGES_FAILED" "$ERROR_DETAILS"
        exit 1
    fi
else
    echo "✅ Decision: No sync needed"
    echo "🏠 No sync required - system is up-to-date"
    if ! current_task_count=$(get_task_count); then
        write_summary_log "ERROR" "STATUS_FAILED" "Unable to query pending tasks"
        exit 1
    fi
    recovery_info=""
    if config_true "$RUN_NAUTICAL_ON_NO_SYNC"; then
        if run_nautical_recovery; then
            recovery_info=", Nautical recovery ok"
        else
            echo "❌ Nautical recovery reported findings or errors"
            write_summary_log "ERROR" "NAUTICAL_RECOVERY_FAILED" "No-sync Nautical recovery failed"
            exit 1
        fi
    fi
    if [ -f "$SYNC_STATE_FILE" ]; then
        echo "📅 Last sync: $LAST_SYNC_SYSTEM at $LAST_SYNC_TIME ($LAST_SYNC_TYPE)"
        write_summary_log "INFO" "NO_SYNC_NEEDED" "up-to-date, $current_task_count pending tasks, last sync: $LAST_SYNC_SYSTEM at $LAST_SYNC_TIME$recovery_info"
    else
        write_summary_log "INFO" "NO_SYNC_NEEDED" "up-to-date, $current_task_count pending tasks, no previous sync state$recovery_info"
    fi
fi
