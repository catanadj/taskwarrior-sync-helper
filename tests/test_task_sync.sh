#!/bin/sh

set -u

PROJECT_DIR=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/task-sync-tests.XXXXXX") || exit 1
failures=0
tests_run=0

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup 0

pass() {
    tests_run=$((tests_run + 1))
    printf 'ok %s - %s\n' "$tests_run" "$1"
}

fail() {
    tests_run=$((tests_run + 1))
    failures=$((failures + 1))
    printf 'not ok %s - %s\n' "$tests_run" "$1"
    if [ -f "$CASE_DIR/output" ]; then
        sed 's/^/  | /' "$CASE_DIR/output"
    fi
}

assert_status() {
    expected=$1
    description=$2
    if [ "$CASE_STATUS" -eq "$expected" ]; then
        pass "$description"
    else
        fail "$description (expected status $expected, got $CASE_STATUS)"
    fi
}

assert_output_contains() {
    expected=$1
    description=$2
    if grep -F "$expected" "$CASE_DIR/output" >/dev/null 2>&1; then
        pass "$description"
    else
        fail "$description (missing: $expected)"
    fi
}

assert_file_contains() {
    file=$1
    expected=$2
    description=$3
    if [ -f "$file" ] && grep -F "$expected" "$file" >/dev/null 2>&1; then
        pass "$description"
    else
        fail "$description (missing: $expected in $file)"
    fi
}

assert_file_exists() {
    file=$1
    description=$2
    if [ -f "$file" ]; then
        pass "$description"
    else
        fail "$description (missing file: $file)"
    fi
}

assert_no_shared_signal() {
    description=$1
    set -- "$CASE_DIR/shared"/*.signal
    if [ "$1" = "$CASE_DIR/shared/*.signal" ]; then
        pass "$description"
    else
        fail "$description"
    fi
}

assert_no_sync_call() {
    description=$1
    if ! grep -x 'sync' "$CASE_DIR/calls" >/dev/null 2>&1; then
        pass "$description"
    else
        fail "$description"
    fi
}

assert_sync_call() {
    description=$1
    if grep -x 'sync' "$CASE_DIR/calls" >/dev/null 2>&1; then
        pass "$description"
    else
        fail "$description"
    fi
}

new_case() {
    name=$1
    CASE_DIR="$TEST_ROOT/$name"
    mkdir -p "$CASE_DIR"
    cp "$PROJECT_DIR/task_sync.sh" "$CASE_DIR/task_sync.sh"
    chmod +x "$CASE_DIR/task_sync.sh"
    : > "$CASE_DIR/calls"

    cat > "$CASE_DIR/mock-task" <<'EOF'
#!/bin/sh

printf '%s\n' "$*" >> "$MOCK_CALL_LOG"

if [ "${1-}" = "--version" ]; then
    if [ "${MOCK_VERSION_STATUS:-0}" -ne 0 ]; then
        exit "$MOCK_VERSION_STATUS"
    fi
    echo "3.4.2"
    exit 0
fi

if [ "${1-}" = "sync" ]; then
    echo "Sync attempted"
    if [ -n "${MOCK_SIGNAL_DURING_SYNC_FILE:-}" ]; then
        signal_tmp="${MOCK_SIGNAL_DURING_SYNC_FILE}.tmp.$$"
        {
            echo "SIGNAL_VERSION=1"
            echo "DEVICE_ID=racing-device"
            echo "GENERATION=${MOCK_SIGNAL_DURING_SYNC_GENERATION:-2}"
            echo "UPDATED_AT=during-sync"
        } > "$signal_tmp" || exit 9
        mv "$signal_tmp" "$MOCK_SIGNAL_DURING_SYNC_FILE" || exit 9
    fi
    exit "${MOCK_SYNC_STATUS:-0}"
fi

case " $* " in
    *" status:pending count "*)
        if [ "${MOCK_COUNT_STATUS:-0}" -ne 0 ]; then
            echo "count failed" >&2
            exit "$MOCK_COUNT_STATUS"
        fi
        echo "${MOCK_PENDING_COUNT:-3}"
        exit 0
        ;;
    *" stats "*)
        case "${MOCK_MODE:-none}" in
            local-v3)
                echo "Sync backlog transactions  6"
                ;;
            local-v2)
                echo "Pending  3"
                ;;
            probe-error)
                echo "Pending  3"
                ;;
            *)
                echo "Sync backlog transactions  0"
                ;;
        esac
        exit 0
        ;;
    *" due:today list "*)
        case "${MOCK_MODE:-none}" in
            local-v3)
                case " $* " in
                    *" rc.verbose=footnote,sync "*)
                        echo "There are 6 local changes.  Sync required." >&2
                        echo "A later diagnostic line" >&2
                        ;;
                esac
                exit 0
                ;;
            local-v2)
                case " $* " in
                    *" rc.verbose=footnote,sync "*)
                        echo "There are local changes.  Sync required." >&2
                        echo "A later diagnostic line" >&2
                        ;;
                esac
                exit 0
                ;;
            probe-error)
                echo "probe failed" >&2
                exit 2
                ;;
            *)
                echo "No matches."
                exit 1
                ;;
        esac
        ;;
esac

echo "unexpected mock invocation: $*" >&2
exit 2
EOF
    chmod +x "$CASE_DIR/mock-task"
}

run_case() {
    mode=$1
    shift
    env \
        TASK_SYNC_CONFIG=/dev/null \
        TASK_BIN="$CASE_DIR/mock-task" \
        LOCK_DIR="$CASE_DIR/lock" \
        LOG_DIR="$CASE_DIR/logs" \
        SHARED_SIGNAL_DIR="$CASE_DIR/shared" \
        LOCAL_STATE_DIR="$CASE_DIR/local-state" \
        SYNC_DEVICE_ID=test-device \
        MOCK_CALL_LOG="$CASE_DIR/calls" \
        MOCK_MODE="$mode" \
        "$@" \
        "$CASE_DIR/task_sync.sh" > "$CASE_DIR/output" 2>&1
    CASE_STATUS=$?
}

new_case local_v3
run_case local-v3
assert_status 0 "Taskwarrior 3 local changes sync successfully"
assert_output_contains "6 local operations need syncing" "operation count is not described as a task count"
assert_file_contains "$CASE_DIR/calls" "stats" "Taskwarrior 3 uses the sync backlog"
assert_sync_call "local changes invoke task sync"
assert_file_contains "$CASE_DIR/shared"/*.signal "GENERATION=1" "successful local sync publishes its generation"
assert_file_contains "$CASE_DIR/local-state/seen_signals" "=1" "publisher records its own generation locally"

new_case local_v2
run_case local-v2
assert_status 0 "Taskwarrior 2 reminder without a count is supported"
assert_output_contains "Syncing local changes" "missing operation count does not look like a remote pull"
assert_file_contains "$CASE_DIR/calls" "rc.verbose=footnote,sync" "Taskwarrior 2 fallback forces sync footnotes"

new_case first_run
run_case none
assert_status 0 "first run performs a conservative sync"
assert_file_exists "$CASE_DIR/local-state/seen_signals" "first run initializes its local signal cursor"
: > "$CASE_DIR/calls"
run_case none
assert_status 0 "second unchanged run succeeds"
assert_no_sync_call "initialized cursor prevents repeated first-run syncs"

new_case legacy_state
printf 'BROKEN=yes\n' > "$CASE_DIR/last_sync_state"
run_case none
assert_status 0 "legacy shared state triggers a migration sync"
assert_output_contains "Legacy last_sync_state detected" "legacy-state migration is reported"
assert_file_exists "$CASE_DIR/local-state/seen_signals" "migration creates a local cursor"

new_case count_failure
run_case none MOCK_COUNT_STATUS=2
if [ "$CASE_STATUS" -ne 0 ]; then
    pass "Taskwarrior preflight failure exits nonzero"
else
    fail "Taskwarrior preflight failure exits nonzero"
fi
assert_no_sync_call "preflight failure does not attempt sync"

new_case probe_failure
run_case probe-error
if [ "$CASE_STATUS" -ne 0 ]; then
    pass "sync-status probe failure exits nonzero"
else
    fail "sync-status probe failure exits nonzero"
fi
assert_no_sync_call "probe failure does not attempt sync"

new_case sync_failure
run_case local-v3 MOCK_SYNC_STATUS=7
if [ "$CASE_STATUS" -ne 0 ]; then
    pass "task sync failure exits nonzero"
else
    fail "task sync failure exits nonzero"
fi
assert_no_shared_signal "failed sync does not publish a shared generation"
assert_file_exists "$CASE_DIR/local-state/pending_generation" "failed sync retains its pending publication"
: > "$CASE_DIR/calls"
run_case none
assert_status 0 "pending publication retries through a successful sync"
assert_output_contains "Completing pending signal publication" "pending publication retry is reported"
assert_sync_call "pending publication forces a safe sync retry"
assert_file_contains "$CASE_DIR/shared"/*.signal "GENERATION=1" "retry publishes the reserved generation"
if [ ! -f "$CASE_DIR/local-state/pending_generation" ]; then
    pass "successful retry clears pending publication"
else
    fail "successful retry clears pending publication"
fi

new_case missing_nautical
run_case local-v3 RUN_NAUTICAL_CHAIN_REPAIR=1 NAUTICAL_TOOLS_DIR="$CASE_DIR/missing-tools"
if [ "$CASE_STATUS" -ne 0 ]; then
    pass "missing enabled Nautical tool exits nonzero"
else
    fail "missing enabled Nautical tool exits nonzero"
fi
assert_no_sync_call "failed pre-sync recovery does not upload partial changes"

new_case no_sync_nautical_failure
run_case none
: > "$CASE_DIR/calls"
run_case none RUN_NAUTICAL_ON_NO_SYNC=1 RUN_NAUTICAL_CHAIN_REPAIR=1 NAUTICAL_TOOLS_DIR="$CASE_DIR/missing-tools"
if [ "$CASE_STATUS" -ne 0 ]; then
    pass "missing no-sync Nautical tool exits nonzero"
else
    fail "missing no-sync Nautical tool exits nonzero"
fi
assert_no_sync_call "no-sync recovery failure does not invoke task sync"

new_case stale_lock
mkdir "$CASE_DIR/lock"
printf '99999999\n' > "$CASE_DIR/lock/pid"
run_case none
assert_status 0 "stale local lock is recovered"
assert_output_contains "Recovered stale task sync lock" "stale-lock recovery is visible"

new_case active_lock
mkdir "$CASE_DIR/lock"
printf '%s\n' "$$" > "$CASE_DIR/lock/pid"
run_case none
if [ "$CASE_STATUS" -ne 0 ]; then
    pass "active local lock exits nonzero"
else
    fail "active local lock exits nonzero"
fi
assert_no_sync_call "active lock prevents Taskwarrior access"

new_case periodic_fallback
run_case none
: > "$CASE_DIR/calls"
printf '0\n' > "$CASE_DIR/local-state/last_success_epoch"
run_case none
assert_status 0 "periodic fallback sync succeeds"
assert_output_contains "Periodic fallback sync is due" "expired fallback interval is reported"
assert_sync_call "expired fallback interval catches unannounced remote work"

new_case multi_device
run_case local-v3 SYNC_DEVICE_ID=device-a LOCAL_STATE_DIR="$CASE_DIR/local-a"
assert_status 0 "device A publishes its first generation"
: > "$CASE_DIR/calls"
run_case none SYNC_DEVICE_ID=device-b LOCAL_STATE_DIR="$CASE_DIR/local-b"
assert_status 0 "new device B syncs the shared snapshot"
assert_sync_call "device B pulls device A's generation"
: > "$CASE_DIR/calls"
run_case none SYNC_DEVICE_ID=device-b LOCAL_STATE_DIR="$CASE_DIR/local-b"
assert_no_sync_call "device B does not acknowledge through a shared write"
run_case local-v3 SYNC_DEVICE_ID=device-a LOCAL_STATE_DIR="$CASE_DIR/local-a"
assert_file_contains "$CASE_DIR/shared"/*.signal "GENERATION=2" "device A advances only its own generation"
: > "$CASE_DIR/calls"
run_case none SYNC_DEVICE_ID=device-b LOCAL_STATE_DIR="$CASE_DIR/local-b"
assert_sync_call "device B observes device A's advanced generation"

new_case signal_race
mkdir -p "$CASE_DIR/shared"
cat > "$CASE_DIR/shared/racing-device.signal" <<'EOF'
SIGNAL_VERSION=1
DEVICE_ID=racing-device
GENERATION=1
UPDATED_AT=before-sync
EOF
run_case none \
    SYNC_DEVICE_ID=device-b \
    LOCAL_STATE_DIR="$CASE_DIR/local-b" \
    MOCK_SIGNAL_DURING_SYNC_FILE="$CASE_DIR/shared/racing-device.signal" \
    MOCK_SIGNAL_DURING_SYNC_GENERATION=2
assert_status 0 "sync succeeds while another generation advances"
assert_file_contains "$CASE_DIR/local-b/seen_signals" "racing-device=1" "cursor commits only the pre-sync snapshot"
: > "$CASE_DIR/calls"
run_case none SYNC_DEVICE_ID=device-b LOCAL_STATE_DIR="$CASE_DIR/local-b"
assert_sync_call "generation arriving during sync remains pending"
: > "$CASE_DIR/calls"
run_case none SYNC_DEVICE_ID=device-b LOCAL_STATE_DIR="$CASE_DIR/local-b"
assert_no_sync_call "second sync acknowledges the advanced generation"

new_case invalid_signal
mkdir -p "$CASE_DIR/shared"
printf 'BROKEN=yes\n' > "$CASE_DIR/shared/broken.signal"
run_case none
if [ "$CASE_STATUS" -ne 0 ]; then
    pass "invalid shared signal exits nonzero"
else
    fail "invalid shared signal exits nonzero"
fi
assert_no_sync_call "invalid signal is not silently acknowledged"

printf '1..%s\n' "$tests_run"
if [ "$failures" -ne 0 ]; then
    printf '%s test assertions failed\n' "$failures" >&2
    exit 1
fi
