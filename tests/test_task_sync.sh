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
assert_file_contains "$CASE_DIR/last_sync_state" "LAST_SYNC_TYPE=WITH_CHANGES" "successful local sync records shared state"

new_case local_v2
run_case local-v2
assert_status 0 "Taskwarrior 2 reminder without a count is supported"
assert_output_contains "Syncing local changes" "missing operation count does not look like a remote pull"
assert_file_contains "$CASE_DIR/calls" "rc.verbose=footnote,sync" "Taskwarrior 2 fallback forces sync footnotes"

new_case first_run
run_case none
assert_status 0 "first run performs a conservative sync"
assert_file_contains "$CASE_DIR/last_sync_state" "LAST_SYNC_TYPE=NO_CHANGES" "first run initializes shared state"
: > "$CASE_DIR/calls"
run_case none
assert_status 0 "second unchanged run succeeds"
assert_no_sync_call "initialized no-change state prevents repeated first-run syncs"

new_case corrupt_state
printf 'BROKEN=yes\n' > "$CASE_DIR/last_sync_state"
run_case none
assert_status 0 "corrupt shared state triggers a conservative sync"
assert_output_contains "incomplete or invalid" "corrupt state is reported"
assert_file_contains "$CASE_DIR/last_sync_state" "LAST_SYNC_TYPE=NO_CHANGES" "corrupt state is replaced after success"

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
if [ ! -f "$CASE_DIR/last_sync_state" ]; then
    pass "failed sync does not publish shared state"
else
    fail "failed sync does not publish shared state"
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

printf '1..%s\n' "$tests_run"
if [ "$failures" -ne 0 ]; then
    printf '%s test assertions failed\n' "$failures" >&2
    exit 1
fi
