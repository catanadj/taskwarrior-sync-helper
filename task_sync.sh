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

device_sync_id=$(lookup_device_path "$DEVICE_SYNC_IDS")
SYNC_DEVICE_ID="${device_sync_id:-${SYNC_DEVICE_ID:-$current_system}}"
if [ -z "$SYNC_DEVICE_ID" ]; then
    echo "❌ SYNC_DEVICE_ID must not be empty"
    exit 1
fi
newline='
'
case "$SYNC_DEVICE_ID" in
    *"$newline"*)
        echo "❌ SYNC_DEVICE_ID must not contain a newline"
        exit 1
        ;;
esac
SYNC_DEVICE_ID_SAFE=$(printf '%s' "$SYNC_DEVICE_ID" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-')
SYNC_DEVICE_ID_CHECKSUM=$(printf '%s' "$SYNC_DEVICE_ID" | cksum | awk '{ print $1 }')
SIGNAL_DEVICE_KEY="${SYNC_DEVICE_ID_SAFE}-${SYNC_DEVICE_ID_CHECKSUM}"

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
FORCE_SYNC_INTERVAL_SECONDS="${FORCE_SYNC_INTERVAL_SECONDS:-86400}"
case "$FORCE_SYNC_INTERVAL_SECONDS" in
    ''|*[!0-9]*|0[0-9]*)
        echo "❌ FORCE_SYNC_INTERVAL_SECONDS must be a non-negative integer"
        exit 1
        ;;
esac

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

cleanup_runtime() {
    cleanup_lock
    if [ -n "${SIGNAL_SNAPSHOT_FILE:-}" ]; then
        rm -f "$SIGNAL_SNAPSHOT_FILE" "${SIGNAL_SNAPSHOT_FILE}.unsorted"
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

trap cleanup_runtime 0
trap 'cleanup_runtime; exit 130' INT
trap 'cleanup_runtime; exit 143' TERM

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

# Cross-device notifications are single-writer generation files. Each device
# acknowledges a captured snapshot in local state, never in the shared folder.
SHARED_SIGNAL_DIR="${SHARED_SIGNAL_DIR:-$SCRIPT_DIR/sync_signals}"
SHARED_SIGNAL_DIR=$(path_from_script_dir "$SHARED_SIGNAL_DIR")

repository_key=$(printf '%s' "$SCRIPT_DIR" | cksum | awk '{ print $1 }')
local_state_home="${XDG_STATE_HOME:-${HOME:-$runtime_dir}/.local/state}"
device_local_state_dir=$(lookup_device_path "$DEVICE_LOCAL_STATE_DIRS")
LOCAL_STATE_DIR="${device_local_state_dir:-${LOCAL_STATE_DIR:-$local_state_home/taskwarrior-sync-helper/${repository_key}-${SIGNAL_DEVICE_KEY}}}"
LOCAL_STATE_DIR=$(path_from_script_dir "$LOCAL_STATE_DIR")

if ! mkdir -p "$SHARED_SIGNAL_DIR" "$LOCAL_STATE_DIR"; then
    echo "❌ Unable to create sync signal or local state directory"
    exit 1
fi

LOCAL_CURSOR_FILE="$LOCAL_STATE_DIR/seen_signals"
LOCAL_GENERATION_FILE="$LOCAL_STATE_DIR/published_generation"
PENDING_GENERATION_FILE="$LOCAL_STATE_DIR/pending_generation"
LAST_SUCCESS_FILE="$LOCAL_STATE_DIR/last_success_epoch"
OWN_SIGNAL_FILE="$SHARED_SIGNAL_DIR/${SIGNAL_DEVICE_KEY}.signal"
SIGNAL_SNAPSHOT_FILE="$LOCAL_STATE_DIR/signal_snapshot.$$"
LEGACY_SYNC_STATE_FILE="$SCRIPT_DIR/last_sync_state"

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

# Read the one generation value from a shared signal file.
read_signal_generation() {
    signal_file="$1"
    awk -F= '
        $1 == "GENERATION" { count++; value = $2 }
        END {
            if (count == 1 && value ~ /^(0|[1-9][0-9]*)$/) {
                print value
                exit 0
            }
            exit 1
        }
    ' "$signal_file" 2>/dev/null
}

read_numeric_state() {
    numeric_file="$1"
    numeric_value=$(sed -n '1p' "$numeric_file" 2>/dev/null)
    case "$numeric_value" in
        ''|*[!0-9]*|0[0-9]*) return 1 ;;
    esac
    if [ "$(wc -l < "$numeric_file" 2>/dev/null)" -ne 1 ]; then
        return 1
    fi
    printf '%s\n' "$numeric_value"
}

write_numeric_state() {
    numeric_file="$1"
    numeric_value="$2"
    numeric_tmp="${numeric_file}.tmp.$$"
    printf '%s\n' "$numeric_value" > "$numeric_tmp" || return 1
    mv "$numeric_tmp" "$numeric_file"
}

# Capture a sorted point-in-time view. Signals arriving or advancing after this
# capture remain different from the committed local cursor and trigger another
# sync on the next run.
capture_signal_snapshot() {
    snapshot_target="$1"
    snapshot_unsorted="${snapshot_target}.unsorted"
    : > "$snapshot_unsorted" || return 1

    for signal_file in "$SHARED_SIGNAL_DIR"/*.signal; do
        [ -f "$signal_file" ] || continue
        signal_name=${signal_file##*/}
        signal_key=${signal_name%.signal}
        if ! signal_generation=$(read_signal_generation "$signal_file"); then
            echo "❌ Invalid shared sync signal: $signal_file" >&2
            rm -f "$snapshot_unsorted"
            return 1
        fi
        printf '%s=%s\n' "$signal_key" "$signal_generation" >> "$snapshot_unsorted" || {
            rm -f "$snapshot_unsorted"
            return 1
        }
    done

    if ! LC_ALL=C sort "$snapshot_unsorted" > "$snapshot_target"; then
        rm -f "$snapshot_unsorted" "$snapshot_target"
        return 1
    fi
    rm -f "$snapshot_unsorted"
}

commit_signal_snapshot() {
    cursor_tmp="${LOCAL_CURSOR_FILE}.tmp.$$"
    cp "$SIGNAL_SNAPSHOT_FILE" "$cursor_tmp" || return 1
    mv "$cursor_tmp" "$LOCAL_CURSOR_FILE"
}

cursor_set_generation() {
    cursor_key="$1"
    cursor_generation="$2"
    cursor_unsorted="${LOCAL_CURSOR_FILE}.unsorted.$$"
    cursor_tmp="${LOCAL_CURSOR_FILE}.tmp.$$"

    if [ -f "$LOCAL_CURSOR_FILE" ]; then
        awk -F= -v key="$cursor_key" '$1 != key' "$LOCAL_CURSOR_FILE" > "$cursor_unsorted" || return 1
    else
        : > "$cursor_unsorted" || return 1
    fi
    printf '%s=%s\n' "$cursor_key" "$cursor_generation" >> "$cursor_unsorted" || return 1
    if ! LC_ALL=C sort "$cursor_unsorted" > "$cursor_tmp"; then
        rm -f "$cursor_unsorted" "$cursor_tmp"
        return 1
    fi
    rm -f "$cursor_unsorted"
    mv "$cursor_tmp" "$LOCAL_CURSOR_FILE"
}

load_pending_generation() {
    if [ ! -f "$PENDING_GENERATION_FILE" ]; then
        return 1
    fi
    if ! PENDING_GENERATION=$(read_numeric_state "$PENDING_GENERATION_FILE"); then
        echo "❌ Invalid pending publication state: $PENDING_GENERATION_FILE" >&2
        return 2
    fi
    return 0
}

# Reserve a durable generation before uploading local changes. If the process
# dies after `task sync` but before publishing, the pending reservation forces a
# safe retry and prevents the notification from being lost.
ensure_pending_generation() {
    load_pending_generation
    pending_status=$?
    if [ "$pending_status" -eq 0 ]; then
        return 0
    fi
    if [ "$pending_status" -eq 2 ]; then
        return 1
    fi

    max_generation=0
    if [ -f "$LOCAL_GENERATION_FILE" ]; then
        if ! local_generation=$(read_numeric_state "$LOCAL_GENERATION_FILE"); then
            echo "❌ Invalid local generation state: $LOCAL_GENERATION_FILE" >&2
            return 1
        fi
        max_generation="$local_generation"
    fi
    if [ -f "$OWN_SIGNAL_FILE" ]; then
        if ! shared_generation=$(read_signal_generation "$OWN_SIGNAL_FILE"); then
            echo "❌ Invalid own shared signal: $OWN_SIGNAL_FILE" >&2
            return 1
        fi
        if [ "$shared_generation" -gt "$max_generation" ]; then
            max_generation="$shared_generation"
        fi
    fi

    PENDING_GENERATION=$((max_generation + 1))
    write_numeric_state "$PENDING_GENERATION_FILE" "$PENDING_GENERATION"
}

publish_pending_generation() {
    if ! load_pending_generation; then
        return 1
    fi

    if [ -f "$OWN_SIGNAL_FILE" ]; then
        if ! current_shared_generation=$(read_signal_generation "$OWN_SIGNAL_FILE"); then
            echo "❌ Invalid own shared signal: $OWN_SIGNAL_FILE" >&2
            return 1
        fi
        if [ "$current_shared_generation" -gt "$PENDING_GENERATION" ]; then
            echo "❌ Own signal advanced unexpectedly; SYNC_DEVICE_ID may be used by another device" >&2
            return 1
        fi
    fi

    signal_tmp="${OWN_SIGNAL_FILE}.tmp.$$"
    {
        echo "SIGNAL_VERSION=1"
        echo "DEVICE_ID=$SYNC_DEVICE_ID"
        echo "GENERATION=$PENDING_GENERATION"
        echo "UPDATED_AT=$(current_timestamp)"
    } > "$signal_tmp" || return 1
    mv "$signal_tmp" "$OWN_SIGNAL_FILE"
}

finalize_local_sync_signal() {
    if ! publish_pending_generation; then
        return 1
    fi
    if ! commit_signal_snapshot; then
        return 1
    fi
    if ! cursor_set_generation "$SIGNAL_DEVICE_KEY" "$PENDING_GENERATION"; then
        return 1
    fi
    if ! write_numeric_state "$LOCAL_GENERATION_FILE" "$PENDING_GENERATION"; then
        return 1
    fi
    rm -f "$PENDING_GENERATION_FILE"
}

record_successful_sync() {
    sync_epoch=$(date '+%s')
    case "$sync_epoch" in
        ''|*[!0-9]*) return 1 ;;
    esac
    write_numeric_state "$LAST_SUCCESS_FILE" "$sync_epoch"
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

    if [ "$sync_type" = "WITH_CHANGES" ] && ! ensure_pending_generation; then
        SCRIPT_RESULT="ERROR"
        ERROR_DETAILS="Unable to reserve a sync signal generation"
        return 1
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

    # Publish local work and acknowledge only the snapshot captured before the
    # sync. A later signal is deliberately left pending for the next run.
    if [ "$sync_type" = "WITH_CHANGES" ]; then
        if ! finalize_local_sync_signal; then
            SCRIPT_RESULT="ERROR"
            ERROR_DETAILS="Unable to publish or commit sync signal state"
            return 1
        fi
    else
        probe_local_changes
        post_probe_status=$?
        if [ "$post_probe_status" -eq 0 ]; then
            echo "⚠️  Local changes remain after pulling remote changes"
            CHANGES_INFO="$CHANGES_INFO (local changes remain)"
        elif [ "$post_probe_status" -eq 2 ]; then
            SCRIPT_RESULT="ERROR"
            ERROR_DETAILS="Unable to verify local state after sync"
            return 1
        fi
        if ! commit_signal_snapshot; then
            SCRIPT_RESULT="ERROR"
            ERROR_DETAILS="Unable to commit local signal cursor"
            return 1
        fi
    fi

    if ! record_successful_sync; then
        SCRIPT_RESULT="ERROR"
        ERROR_DETAILS="Unable to record successful sync time"
        return 1
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

# A pending publication means a previous run may have uploaded local changes but
# exited before notifying other devices. Force a safe sync and republish it.
pending_publication=0
load_pending_generation
pending_status=$?
case "$pending_status" in
    0)
        pending_publication=1
        has_local_changes=1
        echo "📤 Pending generation $PENDING_GENERATION still needs publication"
        ;;
    1) ;;
    *)
        write_summary_log "ERROR" "LOCAL_STATE_INVALID" "Pending generation state is invalid"
        exit 1
        ;;
esac

if ! capture_signal_snapshot "$SIGNAL_SNAPSHOT_FILE"; then
    write_summary_log "ERROR" "SIGNAL_SNAPSHOT_FAILED" "Unable to read shared sync signals"
    exit 1
fi

# Compare the captured shared generations with this device's local cursor.
need_sync_for_different_system=0
if [ ! -f "$LOCAL_CURSOR_FILE" ]; then
    if [ -f "$LEGACY_SYNC_STATE_FILE" ]; then
        echo "🔁 Legacy last_sync_state detected; running a one-time migration sync"
    else
        echo "🆕 No local signal cursor found - this appears to be the first run"
    fi
    need_sync_for_different_system=1
elif cmp -s "$SIGNAL_SNAPSHOT_FILE" "$LOCAL_CURSOR_FILE"; then
    echo "✅ This device has observed all current shared generations"
else
    echo "🔄 One or more device generations changed"
    echo "📥 Current device $SYNC_DEVICE_ID has not synced this signal snapshot"
    need_sync_for_different_system=1
fi
shared_signal_count=$(awk 'END { print NR + 0 }' "$SIGNAL_SNAPSHOT_FILE")

# Signals cover helper-managed clients. A periodic full sync also catches
# clients that bypass the helper or a notification missed by the shared folder.
forced_sync_due=0
if [ "$FORCE_SYNC_INTERVAL_SECONDS" -gt 0 ]; then
    current_epoch=$(date '+%s')
    case "$current_epoch" in
        ''|*[!0-9]*)
            write_summary_log "ERROR" "CLOCK_FAILED" "Unable to read current epoch time"
            exit 1
            ;;
    esac

    if ! last_success_epoch=$(read_numeric_state "$LAST_SUCCESS_FILE"); then
        forced_sync_due=1
    elif [ "$current_epoch" -lt "$last_success_epoch" ] || [ $((current_epoch - last_success_epoch)) -ge "$FORCE_SYNC_INTERVAL_SECONDS" ]; then
        forced_sync_due=1
    fi

    if [ "$forced_sync_due" -eq 1 ]; then
        echo "⏰ Periodic fallback sync is due"
        need_sync_for_different_system=1
    fi
fi

# Debug output
echo "🔧 Debug Information:"
echo "   📊 Local changes: $([ "$has_local_changes" -eq 1 ] && { [ -n "$local_operations_count" ] && echo "$local_operations_count operations" || echo "detected"; } || echo "none")"
echo "   📋 Current pending tasks: $initial_task_count"
echo "   🆔 Sync device ID: $SYNC_DEVICE_ID"
echo "   📡 Shared generations: $shared_signal_count"
echo "   📤 Pending publication: $([ "$pending_publication" -eq 1 ] && echo "YES" || echo "NO")"
echo "   ⏰ Periodic fallback due: $([ "$forced_sync_due" -eq 1 ] && echo "YES" || echo "NO")"
echo "   🔄 Need remote sync: $([ "$need_sync_for_different_system" -eq 1 ] && echo "YES" || echo "NO")"

# Determine sync action
if [ "$has_local_changes" -eq 1 ]; then
    local_sync_reason="Local changes detected"
    if [ "$pending_publication" -eq 1 ] && [ -z "$local_operations_count" ]; then
        local_sync_reason="Completing pending signal publication"
    fi
    echo "🚀 Decision: $local_sync_reason"
    if perform_sync "$local_sync_reason" "$local_operations_count" "WITH_CHANGES"; then
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
    write_summary_log "INFO" "NO_SYNC_NEEDED" "up-to-date, $current_task_count pending tasks, $shared_signal_count shared generations$recovery_info"
fi
