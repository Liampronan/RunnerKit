#!/bin/bash
# Comprehensive cross-platform stub test harness for runnerkit.
# Runs under both /bin/bash 3.2 (macOS) and Bash 5+ (Linux).

set -euo pipefail

REPO_ROOT=$(cd -P "$(dirname "$0")/.." && pwd)
RUNNERKIT="${REPO_ROOT}/bin/runnerkit"
INSTALL_SH="${REPO_ROOT}/install.sh"
STUBS_DIR="${REPO_ROOT}/tests/stubs"

chmod +x "$RUNNERKIT" "$INSTALL_SH" "${STUBS_DIR}"/*

TMP_BASE=$(mktemp -d "${TMPDIR:-/tmp}/runnerkit-tests.XXXXXX")
trap 'rm -rf "$TMP_BASE"' EXIT

ORIG_PATH="$PATH"
HAS_JQ=0
if command -v jq >/dev/null 2>&1; then
  HAS_JQ=1
fi

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf '  ok - %s\n' "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '  FAIL - %s\n' "$1" >&2
  if [ -n "${2:-}" ]; then
    printf '    detail: %s\n' "$2" >&2
  fi
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local msg="$3"
  if [ "$expected" != "$actual" ]; then
    fail "$msg" "expected='${expected}' actual='${actual}'"
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="$3"
  if ! printf '%s\n' "$haystack" | grep -F -q -- "$needle"; then
    fail "$msg" "missing '${needle}' in output: ${haystack}"
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="$3"
  if printf '%s\n' "$haystack" | grep -F -q -- "$needle"; then
    fail "$msg" "unexpected '${needle}' in output: ${haystack}"
  fi
}

assert_valid_json() {
  local json_str="$1"
  local msg="$2"
  if [ "$HAS_JQ" -eq 1 ]; then
    if ! printf '%s\n' "$json_str" | jq -e . >/dev/null 2>&1; then
      fail "$msg" "invalid JSON: ${json_str}"
    fi
  else
    assert_contains "$json_str" '"schema": 1' "$msg"
  fi
}

jq_val() {
  local json_str="$1"
  local expr="$2"
  printf '%s\n' "$json_str" | jq -r "$expr"
}

# Set up a fresh isolated environment for a test case.
TEST_SEQ=0
setup_env() {
  local home_suffix="${1:-home}"
  TEST_SEQ=$((TEST_SEQ + 1))
  TEST_ROOT="${TMP_BASE}/t${TEST_SEQ}"
  HOME="${TEST_ROOT}/${home_suffix}"
  STUB_STATE_DIR="${TEST_ROOT}/stub_state"
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs" "$STUB_STATE_DIR/services" "$STUB_STATE_DIR/disabled"
  export HOME STUB_STATE_DIR
  export PATH="${STUBS_DIR}:${ORIG_PATH}"
  export USER="ci"
  export RUNNERKIT_UID="501"
  export RUNNERKIT_HEAL_WAIT="0"
  export RUNNERKIT_NOW_ISO="2026-11-16T20:00:00Z"
  export RUNNERKIT_NOW_EPOCH="1794888000"
  unset RUNNER_NAME STUB_UNAME STUB_HOSTNAME STUB_NO_GUI_SESSION STUB_FREE_GB \
    STUB_XCODE_SELECT_FAIL STUB_XCODEBUILD_FAIL STUB_SIMCTL_FAIL STUB_RUNTIMES_OUTPUT \
    STUB_PMSET_SLEEP STUB_NETWORK_FAIL RUNNERKIT_MAX_LOG_BYTES
}

# Helper to register a fake runner plist, directory, .runner file, and launchctl service state.
add_runner_fixture() {
  local label="$1"
  local agent_name="$2"
  local github_url="$3"
  local dir="$4"
  local loaded="$5"
  local pid="$6"
  local last_exit="$7"
  local with_bom="${8:-0}"
  local create_dir="${9:-1}"

  local log_dir="${HOME}/Library/Logs/${label}"
  mkdir -p "$log_dir" "${HOME}/Library/LaunchAgents"

  if [ "$create_dir" = "1" ]; then
    mkdir -p "${dir}/_diag"
    local bom_prefix=""
    if [ "$with_bom" = "1" ]; then
      bom_prefix=$(printf '\357\273\277')
    fi
    cat >"${dir}/.runner" <<EOF
${bom_prefix}{
  "agentId": 10,
  "agentName": "${agent_name}",
  "gitHubUrl": "${github_url}",
  "workFolder": "_work"
}
EOF
  fi

  cat >"${HOME}/Library/LaunchAgents/${label}.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>${label}</string>
    <key>ProgramArguments</key>
    <array>
      <string>${dir}/runsvc.sh</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${dir}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${log_dir}/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${log_dir}/stderr.log</string>
  </dict>
</plist>
EOF

  cat >"${STUB_STATE_DIR}/services/${label}.svc" <<EOF
LOADED=${loaded}
PID=${pid}
LAST_EXIT=${last_exit}
CRASH_ON_START=0
SPAWN_PID=950
EOF
}

# ---------------------------------------------------------------------------
# 1. No instances found
# ---------------------------------------------------------------------------
test_no_instances() {
  setup_env
  local out rc=0
  out=$("$RUNNERKIT" status) || rc=$?
  assert_eq "0" "$rc" "status with no instances exits 0"
  assert_contains "$out" "no runner instances found" "human output notes no instances"

  local jout
  jout=$("$RUNNERKIT" status --json)
  assert_valid_json "$jout" "no-instances JSON valid"
  if [ "$HAS_JQ" -eq 1 ]; then
    assert_eq "1" "$(jq_val "$jout" '.schema')" "schema version is 1"
    assert_eq "true" "$(jq_val "$jout" '.healthy')" "empty host is healthy"
    assert_eq "0" "$(jq_val "$jout" '.instances | length')" "instances array is empty"
  fi
  pass "no instances found (human and --json)"
}

# ---------------------------------------------------------------------------
# 2. Every base state + org runner + 3-level Runner.Worker hierarchy
# ---------------------------------------------------------------------------
test_all_base_states() {
  setup_env
  add_runner_fixture "actions.runner.acme-app.mac-1" "mac-1" "https://github.com/acme/app" "${TEST_ROOT}/r1" 1 "512" "0"
  add_runner_fixture "actions.runner.acme-app.mac-2" "mac-2" "https://github.com/acme/app" "${TEST_ROOT}/r2" 1 "518" "0"
  add_runner_fixture "actions.runner.acme-app.mac-3" "mac-3" "https://github.com/acme/app" "${TEST_ROOT}/r3" 1 "" "1"
  add_runner_fixture "actions.runner.acme.org-mac-4" "org-mac-4" "https://github.com/acme" "${TEST_ROOT}/r4" 0 "" ""
  add_runner_fixture "actions.runner.acme-app.mac-5" "mac-5" "https://github.com/acme/app" "${TEST_ROOT}/r5" 1 "" "1"
  add_runner_fixture "actions.runner.acme-app.mac-6" "mac-6" "https://github.com/acme/app" "${TEST_ROOT}/missing-dir" 0 "" "" 0 0

  # 3-level process tree under mac-2 (runsvc.sh 518 -> node 600 -> Runner.Listener 601 -> Runner.Worker 602)
  cat >"${STUB_STATE_DIR}/procs" <<'EOF'
600 518 /Users/ci/r2/externals/node24/bin/node ./bin/RunnerService.js
601 600 /Users/ci/r2/bin/Runner.Listener run --startuptype service
602 601 /Users/ci/r2/bin/Runner.Worker spawnclient 10 11
EOF

  printf 'Runner listener exit with terminated error, stop the service\n' >"${HOME}/Library/Logs/actions.runner.acme-app.mac-3/stderr.log"
  cat >"${HOME}/Library/Logs/actions.runner.acme-app.mac-5/stdout.log" <<'EOF'
Starting Runner listener with startup type: service
Failed to create a session. The runner registration has been deleted from the server, please re-configure.
Runner listener exited with error code 1
EOF

  local rc=0 jout
  jout=$("$RUNNERKIT" status --json) || rc=$?
  assert_eq "1" "$rc" "unhealthy instances cause exit 1"
  assert_valid_json "$jout" "all-states JSON valid"

  if [ "$HAS_JQ" -eq 1 ]; then
    assert_eq "false" "$(jq_val "$jout" '.healthy')" "overall healthy is false"
    assert_eq "idle" "$(jq_val "$jout" '.instances[] | select(.name=="mac-1") | .state')" "mac-1 is idle"
    assert_eq "busy" "$(jq_val "$jout" '.instances[] | select(.name=="mac-2") | .state')" "mac-2 is busy via 3-level worker descendant"
    assert_eq "stopped" "$(jq_val "$jout" '.instances[] | select(.name=="mac-3") | .state')" "mac-3 is stopped"
    assert_eq "unloaded" "$(jq_val "$jout" '.instances[] | select(.name=="org-mac-4") | .state')" "org-mac-4 is unloaded"
    assert_eq "https://github.com/acme" "$(jq_val "$jout" '.instances[] | select(.name=="org-mac-4") | .target')" "org-level target preserved"
    assert_eq "rejected" "$(jq_val "$jout" '.instances[] | select(.name=="mac-5") | .state')" "mac-5 is rejected"
    assert_eq "orphaned" "$(jq_val "$jout" '.instances[] | select(.name=="mac-6") | .state')" "mac-6 is orphaned"
  fi
  pass "all base states (idle, busy, stopped, unloaded, rejected, orphaned)"
}

# ---------------------------------------------------------------------------
# 3. UTF-8 BOM in .runner and spaces in $HOME, WorkingDirectory, and runner name
# ---------------------------------------------------------------------------
test_bom_and_spaces() {
  setup_env "ci user home"
  local spaced_dir="${TEST_ROOT}/Actions Runner Dir 1"
  add_runner_fixture "actions.runner.acme-app.build_mac_space" "build mac space" "https://github.com/acme/app" "$spaced_dir" 1 "777" "0" 1 1

  local jout
  jout=$("$RUNNERKIT" status --json)
  assert_valid_json "$jout" "BOM + spaces JSON valid"
  if [ "$HAS_JQ" -eq 1 ]; then
    assert_eq "build mac space" "$(jq_val "$jout" '.instances[0].name')" "BOM stripped and spaced agentName parsed"
    assert_eq "$spaced_dir" "$(jq_val "$jout" '.instances[0].dir')" "spaced WorkingDirectory parsed"
    assert_eq "idle" "$(jq_val "$jout" '.instances[0].state')" "spaced runner is idle"
  fi

  # On real macOS, also verify against native /usr/bin/plutil.
  if [ -x /usr/bin/plutil ]; then
    local real_val
    real_val=$(/usr/bin/plutil -extract WorkingDirectory raw -o - "${HOME}/Library/LaunchAgents/actions.runner.acme-app.build_mac_space.plist")
    assert_eq "$spaced_dir" "$real_val" "native /usr/bin/plutil extracts spaced WorkingDirectory"
  fi
  pass ".runner with UTF-8 BOM and spaces in paths and runner name"
}

# ---------------------------------------------------------------------------
# 4. heal restarts stopped & loads unloaded, leaves busy/idle/rejected/orphaned alone
# ---------------------------------------------------------------------------
test_heal_actions() {
  setup_env
  add_runner_fixture "actions.runner.acme-app.r-idle" "r-idle" "https://github.com/acme/app" "${TEST_ROOT}/ri" 1 "501" "0"
  add_runner_fixture "actions.runner.acme-app.r-busy" "r-busy" "https://github.com/acme/app" "${TEST_ROOT}/rb" 1 "502" "0"
  add_runner_fixture "actions.runner.acme-app.r-stop" "r-stop" "https://github.com/acme/app" "${TEST_ROOT}/rs" 1 "" "1"
  add_runner_fixture "actions.runner.acme-app.r-unld" "r-unld" "https://github.com/acme/app" "${TEST_ROOT}/ru" 0 "" ""
  add_runner_fixture "actions.runner.acme-app.r-rejc" "r-rejc" "https://github.com/acme/app" "${TEST_ROOT}/rr" 1 "" "1"

  printf '610 502 /Users/ci/rb/bin/Runner.Worker spawnclient 1 2\n' >"${STUB_STATE_DIR}/procs"
  printf 'The runner no longer exists on the server. Please reconfigure the runner.\n' >"${HOME}/Library/Logs/actions.runner.acme-app.r-rejc/stderr.log"

  local rc=0 jout
  jout=$("$RUNNERKIT" heal --json) || rc=$?
  assert_eq "1" "$rc" "heal exits 1 because rejected runner remains unfixable"
  assert_valid_json "$jout" "heal JSON valid"

  local calls
  calls=$(cat "${STUB_STATE_DIR}/launchctl.calls")
  assert_contains "$calls" "kickstart -k gui/501/actions.runner.acme-app.r-stop" "stopped runner kickstarted"
  assert_contains "$calls" "bootstrap gui/501 ${HOME}/Library/LaunchAgents/actions.runner.acme-app.r-unld.plist" "unloaded runner bootstrapped"
  assert_not_contains "$calls" "r-idle" "idle runner untouched"
  assert_not_contains "$calls" "r-busy" "busy runner untouched"
  assert_not_contains "$calls" "r-rejc" "rejected runner untouched"

  if [ "$HAS_JQ" -eq 1 ]; then
    assert_eq "idle" "$(jq_val "$jout" '.instances[] | select(.name=="r-stop") | .state')" "r-stop recovered to idle"
    assert_eq "restarted" "$(jq_val "$jout" '.instances[] | select(.name=="r-stop") | .action')" "r-stop action is restarted"
    assert_eq "idle" "$(jq_val "$jout" '.instances[] | select(.name=="r-unld") | .state')" "r-unld recovered to idle"
    assert_eq "loaded" "$(jq_val "$jout" '.instances[] | select(.name=="r-unld") | .action')" "r-unld action is loaded"
  fi
  pass "heal restarts stopped and loads unloaded while skipping idle, busy, rejected"
}

# ---------------------------------------------------------------------------
# 5. Flapping cap across 3 runs, --force override, and reset when seen running
# ---------------------------------------------------------------------------
test_flapping_lifecycle() {
  setup_env
  add_runner_fixture "actions.runner.acme-app.flapper" "flapper" "https://github.com/acme/app" "${TEST_ROOT}/flap" 1 "" "1"
  cat >"${STUB_STATE_DIR}/services/actions.runner.acme-app.flapper.svc" <<'EOF'
LOADED=1
PID=
LAST_EXIT=1
CRASH_ON_START=1
SPAWN_PID=999
EOF

  local j1 j2 j3 j4 rc
  rc=0; j1=$("$RUNNERKIT" heal --json) || rc=$?
  assert_eq "1" "$rc" "heal 1 exits 1"
  rc=0; j2=$("$RUNNERKIT" heal --json) || rc=$?
  assert_eq "1" "$rc" "heal 2 exits 1"
  rc=0; j3=$("$RUNNERKIT" heal --json) || rc=$?
  assert_eq "1" "$rc" "heal 3 exits 1"

  if [ "$HAS_JQ" -eq 1 ]; then
    assert_eq "stopped" "$(jq_val "$j1" '.instances[0].state')" "after 1st failed heal: stopped"
    assert_eq "1" "$(jq_val "$j1" '.instances[0].restarts')" "restarts=1"
    assert_eq "stopped" "$(jq_val "$j2" '.instances[0].state')" "after 2nd failed heal: stopped"
    assert_eq "2" "$(jq_val "$j2" '.instances[0].restarts')" "restarts=2"
    assert_eq "flapping" "$(jq_val "$j3" '.instances[0].state')" "after 3rd failed heal: flapping"
    assert_eq "3" "$(jq_val "$j3" '.instances[0].restarts')" "restarts=3"
  fi

  # 4th heal must NOT touch launchctl.
  : >"${STUB_STATE_DIR}/launchctl.calls"
  rc=0; j4=$("$RUNNERKIT" heal --json) || rc=$?
  assert_eq "1" "$rc" "heal 4 exits 1"
  assert_eq "" "$(cat "${STUB_STATE_DIR}/launchctl.calls")" "flapping runner is left alone on 4th heal"
  if [ "$HAS_JQ" -eq 1 ]; then
    assert_eq "none" "$(jq_val "$j4" '.instances[0].action')" "action is none when flapping"
  fi

  # Now fix CRASH_ON_START and run `heal --force` -> recovers to idle!
  cat >"${STUB_STATE_DIR}/services/actions.runner.acme-app.flapper.svc" <<'EOF'
LOADED=1
PID=
LAST_EXIT=1
CRASH_ON_START=0
SPAWN_PID=888
EOF
  local jf
  jf=$("$RUNNERKIT" heal --force --json)
  if [ "$HAS_JQ" -eq 1 ]; then
    assert_eq "idle" "$(jq_val "$jf" '.instances[0].state')" "heal --force brings flapping runner back to idle"
    assert_eq "restarted" "$(jq_val "$jf" '.instances[0].action')" "action is restarted under --force"
  fi

  # Subsequent status sees it running and resets restarts counter to 0.
  local js
  js=$("$RUNNERKIT" status --json)
  if [ "$HAS_JQ" -eq 1 ]; then
    assert_eq "0" "$(jq_val "$js" '.instances[0].restarts')" "seen running resets restart counter to 0"
  fi
  pass "flapping counter across 3 heals, left alone on 4th, --force, and reset when running"
}

# ---------------------------------------------------------------------------
# 6. RUNNER_NAME self-skip in heal and --dry-run side-effect freedom
# ---------------------------------------------------------------------------
test_self_skip_and_dry_run() {
  setup_env
  add_runner_fixture "actions.runner.acme-app.self-r" "self-r" "https://github.com/acme/app" "${TEST_ROOT}/sr" 1 "" "1"
  add_runner_fixture "actions.runner.acme-app.sib-r" "sib-r" "https://github.com/acme/app" "${TEST_ROOT}/br" 1 "" "1"

  # Dry-run first: must not create state dir or invoke mutating launchctl calls.
  local dry_out rc=0
  dry_out=$("$RUNNERKIT" heal --dry-run) || rc=$?
  assert_eq "1" "$rc" "dry-run still exits 1 while stopped"
  assert_contains "$dry_out" "dry-run: launchctl kickstart -k" "dry-run prints command"
  if [ -d "${HOME}/Library/Application Support/runnerkit/state" ]; then
    fail "dry-run must not create state directory"
  fi
  if [ -f "${STUB_STATE_DIR}/launchctl.calls" ]; then
    fail "dry-run must not execute mutating launchctl commands"
  fi

  # Dry-run with --json must keep stdout pure JSON.
  local dry_json
  rc=0
  dry_json=$("$RUNNERKIT" heal --dry-run --json 2>/dev/null) || rc=$?
  assert_valid_json "$dry_json" "heal --dry-run --json emits pure valid JSON on stdout"

  # Now test RUNNER_NAME self-skip on real heal.
  export RUNNER_NAME="self-r"
  rc=0
  "$RUNNERKIT" heal >/dev/null || rc=$?
  local calls
  calls=$(cat "${STUB_STATE_DIR}/launchctl.calls")
  assert_not_contains "$calls" "self-r" "RUNNER_NAME self instance skipped during heal"
  assert_contains "$calls" "sib-r" "sibling instance healed"
  unset RUNNER_NAME
  pass "RUNNER_NAME self-skip and --dry-run leaves state & launchctl untouched"
}

# ---------------------------------------------------------------------------
# 7. JSON escaping (quotes, backslashes, tabs, newlines) and secret masking
# ---------------------------------------------------------------------------
test_json_escaping_and_masking() {
  setup_env
  add_runner_fixture "actions.runner.acme-app.sec-1" "sec-1" "https://github.com/acme/app" "${TEST_ROOT}/sec1" 1 "" "1"

  cat >"${HOME}/Library/Logs/actions.runner.acme-app.sec-1/stderr.log" <<'EOF'
Error at C:\path\with\backslashes and "double quotes"	and	tabs
Auth header: Bearer superSecretBearerTokenValue12345
GitHub token ghp_1234567890abcdefghijklmnop leaked and --token REGTOKEN987654321
JWT eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U
EOF
  printf '[2026-11-16 20:00:00Z ERR Runner] Fatal Exception with pat=github_pat_11AABBCCDDEEFF00112233\n' \
    >"${TEST_ROOT}/sec1/_diag/Runner_20261116-200000-utc.log"
  printf 'SUPER_SENSITIVE_JOB_OUTPUT_SECRET\n' \
    >"${TEST_ROOT}/sec1/_diag/Worker_20261116-200001-utc.log"

  local jout rc=0
  jout=$("$RUNNERKIT" status --json) || rc=$?
  assert_eq "1" "$rc" "stopped instance exits 1"
  assert_valid_json "$jout" "JSON with quotes, backslashes, tabs parses cleanly"
  assert_not_contains "$jout" "ghp_1234567890" "ghp_ token masked"
  assert_not_contains "$jout" "superSecretBearerTokenValue" "Bearer token masked"
  assert_not_contains "$jout" "REGTOKEN987654321" "--token argument masked"
  assert_not_contains "$jout" "dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U" "JWT masked"
  assert_not_contains "$jout" "github_pat_11AABBCC" "github_pat_ masked"
  assert_not_contains "$jout" "SUPER_SENSITIVE_JOB_OUTPUT_SECRET" "Worker_*.log job log never read"

  local logs_out
  logs_out=$("$RUNNERKIT" logs sec-1 --lines 20)
  assert_contains "$logs_out" "[REDACTED]" "runnerkit logs masks tokens"
  assert_not_contains "$logs_out" "SUPER_SENSITIVE_JOB_OUTPUT_SECRET" "runnerkit logs ignores Worker_*.log"
  pass "JSON escaping and secret masking (status and logs)"
}

# ---------------------------------------------------------------------------
# 8. Update 1: pause & resume full test matrix
# ---------------------------------------------------------------------------
test_pause_and_resume() {
  setup_env
  add_runner_fixture "actions.runner.acme-app.p-idle" "p-idle" "https://github.com/acme/app" "${TEST_ROOT}/pi" 1 "510" "0"
  add_runner_fixture "actions.runner.acme-app.p-busy" "p-busy" "https://github.com/acme/app" "${TEST_ROOT}/pb" 1 "520" "0"
  printf '700 520 /Users/ci/pb/bin/Runner.Worker spawnclient 1 2\n' >"${STUB_STATE_DIR}/procs"

  # 8a. Unknown runner name fails with list of valid names.
  local err_out rc=0
  err_out=$("$RUNNERKIT" pause no-such-runner 2>&1) || rc=$?
  assert_eq "1" "$rc" "pause unknown runner exits 1"
  assert_contains "$err_out" "p-busy, p-idle" "error lists valid runner names"

  # 8b. Pause self (RUNNER_NAME) refused even with --now.
  export RUNNER_NAME="p-idle"
  rc=0
  err_out=$("$RUNNERKIT" pause p-idle --now 2>&1) || rc=$?
  assert_eq "1" "$rc" "pause self with --now refused with exit 1"
  assert_contains "$err_out" "running the current job" "self-pause error message"
  unset RUNNER_NAME

  # 8c. Pause busy runner refused without --now, succeeds with --now.
  rc=0
  err_out=$("$RUNNERKIT" pause p-busy 2>&1) || rc=$?
  assert_eq "1" "$rc" "pause busy without --now exits 1"
  assert_contains "$err_out" "--now" "busy pause error mentions --now"

  local jb_pause
  jb_pause=$("$RUNNERKIT" pause p-busy --now --reason "hung in simulator step" --json)
  assert_valid_json "$jb_pause" "pause --now --json valid"
  if [ "$HAS_JQ" -eq 1 ]; then
    assert_eq "paused" "$(jq_val "$jb_pause" '.instances[] | select(.name=="p-busy") | .state')" "p-busy is now paused"
    assert_eq "paused" "$(jq_val "$jb_pause" '.instances[] | select(.name=="p-busy") | .action')" "p-busy action is paused"
  fi
  assert_contains "$(cat "${STUB_STATE_DIR}/launchctl.calls")" "disable gui/501/actions.runner.acme-app.p-busy" "launchctl disable called"
  assert_contains "$(cat "${STUB_STATE_DIR}/launchctl.calls")" "bootout gui/501/actions.runner.acme-app.p-busy" "launchctl bootout called"

  # Clear busy worker since p-busy was booted out.
  : >"${STUB_STATE_DIR}/procs"

  # 8d. Pause idle runner with quotes, backslashes, and literal newline in reason; then double-pause updates reason.
  local multiline_reason
  multiline_reason=$'simctl hung "boot"\nsee C:\\logs\\sim'
  "$RUNNERKIT" pause p-idle --reason "$multiline_reason" >/dev/null

  local js_paused
  js_paused=$("$RUNNERKIT" status --json)
  assert_valid_json "$js_paused" "status --json with multiline quoted pause reason valid"
  if [ "$HAS_JQ" -eq 1 ]; then
    assert_eq "$multiline_reason" "$(jq_val "$js_paused" '.instances[] | select(.name=="p-idle") | .paused_reason')" "multiline quoted pause reason round-trips"
    assert_eq "true" "$(jq_val "$js_paused" '.healthy')" "paused runners keep status healthy"
  fi

  # Advance clock and double-pause p-idle: updates reason, preserves original paused_since, exits 0.
  export RUNNERKIT_NOW_ISO="2026-11-16T21:00:00Z"
  export RUNNERKIT_NOW_EPOCH="1794891600"
  "$RUNNERKIT" pause p-idle --reason "updated reason" >/dev/null
  js_paused=$("$RUNNERKIT" status --json)
  if [ "$HAS_JQ" -eq 1 ]; then
    assert_eq "updated reason" "$(jq_val "$js_paused" '.instances[] | select(.name=="p-idle") | .paused_reason')" "double pause updates reason"
    assert_eq "2026-11-16T20:00:00Z" "$(jq_val "$js_paused" '.instances[] | select(.name=="p-idle") | .paused_since')" "double pause preserves original paused_since"
  fi

  # 8e. heal leaves paused runners down when already down.
  : >"${STUB_STATE_DIR}/launchctl.calls"
  "$RUNNERKIT" heal >/dev/null
  assert_eq "" "$(cat "${STUB_STATE_DIR}/launchctl.calls")" "heal leaves down paused runners completely alone"

  # 8f. heal stops a paused runner found running and idle (action: stopped_paused).
  cat >"${STUB_STATE_DIR}/services/actions.runner.acme-app.p-idle.svc" <<'EOF'
LOADED=1
PID=611
LAST_EXIT=0
CRASH_ON_START=0
SPAWN_PID=611
EOF
  local jh_stop_paused
  jh_stop_paused=$("$RUNNERKIT" heal --json)
  assert_valid_json "$jh_stop_paused" "heal stopping idle paused runner JSON valid"
  if [ "$HAS_JQ" -eq 1 ]; then
    assert_eq "stopped_paused" "$(jq_val "$jh_stop_paused" '.instances[] | select(.name=="p-idle") | .action')" "action is stopped_paused"
    assert_eq "paused" "$(jq_val "$jh_stop_paused" '.instances[] | select(.name=="p-idle") | .state')" "state remains paused"
    assert_eq "null" "$(jq_val "$jh_stop_paused" '.instances[] | select(.name=="p-idle") | .pid')" "pid is null after stopped_paused"
  fi

  # 8g. heal leaves a paused runner found running & busy, and reports unhealthy (exit 1).
  cat >"${STUB_STATE_DIR}/services/actions.runner.acme-app.p-busy.svc" <<'EOF'
LOADED=1
PID=622
LAST_EXIT=0
CRASH_ON_START=0
SPAWN_PID=622
EOF
  printf '701 622 /Users/ci/pb/bin/Runner.Worker spawnclient 1 2\n' >"${STUB_STATE_DIR}/procs"
  : >"${STUB_STATE_DIR}/launchctl.calls"
  rc=0
  "$RUNNERKIT" heal >/dev/null || rc=$?
  assert_eq "1" "$rc" "heal exits 1 when paused runner is still busy"
  assert_eq "" "$(cat "${STUB_STATE_DIR}/launchctl.calls")" "heal does not kill busy paused runner"
  : >"${STUB_STATE_DIR}/procs"
  cat >"${STUB_STATE_DIR}/services/actions.runner.acme-app.p-busy.svc" <<'EOF'
LOADED=0
PID=
LAST_EXIT=0
CRASH_ON_START=0
SPAWN_PID=622
EOF

  # 8h. Seed restart counter = 3 on p-idle, then resume -> clears pause record, resets counter, enables & bootstraps.
  mkdir -p "${HOME}/Library/Application Support/runnerkit/state"
  printf '{"restarts": 3, "last_attempt": "2026-11-16T20:00:00Z"}\n' \
    >"${HOME}/Library/Application Support/runnerkit/state/actions.runner.acme-app.p-idle.json"
  : >"${STUB_STATE_DIR}/launchctl.calls"
  local jr_out
  jr_out=$("$RUNNERKIT" resume p-idle --json)
  assert_valid_json "$jr_out" "resume --json valid"
  assert_contains "$(cat "${STUB_STATE_DIR}/launchctl.calls")" "enable gui/501/actions.runner.acme-app.p-idle" "resume enables service"
  assert_contains "$(cat "${STUB_STATE_DIR}/launchctl.calls")" "bootstrap gui/501 ${HOME}/Library/LaunchAgents/actions.runner.acme-app.p-idle.plist" "resume bootstraps service"
  if [ "$HAS_JQ" -eq 1 ]; then
    assert_eq "idle" "$(jq_val "$jr_out" '.instances[] | select(.name=="p-idle") | .state')" "resumed runner is idle"
    assert_eq "resumed" "$(jq_val "$jr_out" '.instances[] | select(.name=="p-idle") | .action')" "action is resumed"
    assert_eq "0" "$(jq_val "$jr_out" '.instances[] | select(.name=="p-idle") | .restarts')" "resume resets restart counter"
  fi

  # 8i. Resuming a runner that is not paused succeeds and does nothing.
  : >"${STUB_STATE_DIR}/launchctl.calls"
  "$RUNNERKIT" resume p-idle >/dev/null
  assert_eq "" "$(cat "${STUB_STATE_DIR}/launchctl.calls")" "resuming non-paused runner makes no launchctl calls"
  pass "pause and resume lifecycle (idle, busy/--now, self-refusal, double-pause, multiline reason, heal interactions, resume)"
}

# ---------------------------------------------------------------------------
# 9. doctor checks (disk, session, xcode, runtime, sleep, network, paused warn/fail, summary)
# ---------------------------------------------------------------------------
test_doctor_checks() {
  setup_env
  add_runner_fixture "actions.runner.acme-app.d-1" "d-1" "https://github.com/acme/app" "${TEST_ROOT}/d1" 1 "511" "0"
  add_runner_fixture "actions.runner.acme-app.d-2" "d-2" "https://github.com/acme/app" "${TEST_ROOT}/d2" 1 "512" "0"

  # 9a. Healthy + sleep warn (warn does NOT make doctor fail) + installed runtime iOS-26-5
  export STUB_PMSET_SLEEP="15"
  local doc_ok summary_md="${TEST_ROOT}/summary.md"
  doc_ok=$("$RUNNERKIT" doctor --require-runtime iOS-26-5 --summary "$summary_md" --json)
  assert_valid_json "$doc_ok" "healthy doctor JSON valid"
  if [ "$HAS_JQ" -eq 1 ]; then
    assert_eq "true" "$(jq_val "$doc_ok" '.healthy')" "sleep warn keeps healthy=true"
    assert_eq "warn" "$(jq_val "$doc_ok" '.checks[] | select(.id=="sleep") | .result')" "sleep check is warn"
    assert_eq "ok" "$(jq_val "$doc_ok" '.checks[] | select(.id=="runtime") | .result')" "iOS-26-5 runtime check is ok"
  fi
  assert_contains "$(cat "$summary_md")" "### RunnerKit Report — Healthy" "markdown summary written"

  # 9b. Missing runtime (and unavailable iOS-25-0 must NOT count as installed!)
  local rc=0 doc_rt
  doc_rt=$("$RUNNERKIT" doctor --require-runtime iOS-26-0,iOS-25-0 --json) || rc=$?
  assert_eq "1" "$rc" "missing/unavailable runtime exits 1"
  if [ "$HAS_JQ" -eq 1 ]; then
    assert_eq "fail" "$(jq_val "$doc_rt" '.checks[] | select(.id=="runtime") | .result')" "runtime check fails"
    assert_contains "$(jq_val "$doc_rt" '.checks[] | select(.id=="runtime") | .value')" "have iOS-26-5; Xcode 26.5 selected" "runtime message names installed runtimes and selected Xcode"
  fi

  # 9c. Disk, session, xcode, network failures
  export STUB_FREE_GB="5"
  export STUB_NO_GUI_SESSION="1"
  export STUB_XCODEBUILD_FAIL="1"
  export STUB_NETWORK_FAIL="1"
  rc=0
  local doc_fail
  doc_fail=$("$RUNNERKIT" doctor --min-free-gb 20 --json) || rc=$?
  assert_eq "1" "$rc" "failing machine checks exit 1"
  if [ "$HAS_JQ" -eq 1 ]; then
    assert_eq "fail" "$(jq_val "$doc_fail" '.checks[] | select(.id=="disk") | .result')" "disk check fails"
    assert_eq "fail" "$(jq_val "$doc_fail" '.checks[] | select(.id=="session") | .result')" "session check fails"
    assert_eq "fail" "$(jq_val "$doc_fail" '.checks[] | select(.id=="xcode") | .result')" "xcode check fails"
    assert_eq "fail" "$(jq_val "$doc_fail" '.checks[] | select(.id=="network") | .result')" "network check fails"
  fi
  unset STUB_FREE_GB STUB_NO_GUI_SESSION STUB_XCODEBUILD_FAIL STUB_NETWORK_FAIL STUB_PMSET_SLEEP

  # 9d. paused check at warn (1 of 2 paused) vs fail (all 2 of 2 paused)
  "$RUNNERKIT" pause d-1 --reason "investigating" >/dev/null
  export RUNNERKIT_NOW_EPOCH=$((1794888000 + 8100)) # +2h 15m
  local doc_pwarn
  doc_pwarn=$("$RUNNERKIT" doctor --json)
  if [ "$HAS_JQ" -eq 1 ]; then
    assert_eq "true" "$(jq_val "$doc_pwarn" '.healthy')" "1 of 2 paused keeps doctor healthy=true"
    assert_eq "warn" "$(jq_val "$doc_pwarn" '.checks[] | select(.id=="paused") | .result')" "paused check is warn when 1 of 2 paused"
    assert_contains "$(jq_val "$doc_pwarn" '.checks[] | select(.id=="paused") | .value')" "d-1 (2h 15m)" "paused check shows duration"
  fi

  "$RUNNERKIT" pause d-2 --reason "also paused" >/dev/null
  rc=0
  local doc_pfail
  doc_pfail=$("$RUNNERKIT" doctor --json) || rc=$?
  assert_eq "1" "$rc" "doctor exits 1 when every instance is paused"
  if [ "$HAS_JQ" -eq 1 ]; then
    assert_eq "false" "$(jq_val "$doc_pfail" '.healthy')" "all paused makes doctor healthy=false"
    assert_eq "fail" "$(jq_val "$doc_pfail" '.checks[] | select(.id=="paused") | .result')" "paused check is fail when all paused"
  fi
  pass "doctor checks (disk, session, xcode, runtime, sleep warn, network, paused warn & fail, summary)"
}

# ---------------------------------------------------------------------------
# 10. agent install/status/uninstall, heal.log rotation, install.sh, exit codes 2 & 3
# ---------------------------------------------------------------------------
test_agent_install_and_exit_codes() {
  setup_env
  "$RUNNERKIT" agent install --interval 10 >/dev/null
  local agent_plist="${HOME}/Library/LaunchAgents/io.runnerkit.heal.plist"
  [ -f "$agent_plist" ] || fail "agent plist written"
  assert_eq "600" "$(plutil -extract StartInterval raw -o - "$agent_plist")" "StartInterval is 600s for 10 min"
  assert_contains "$(cat "$agent_plist")" "/opt/homebrew/bin" "agent plist includes Homebrew PATH"

  local st_out
  st_out=$("$RUNNERKIT" agent status)
  assert_contains "$st_out" "agent: loaded" "agent status shows loaded"

  # Log rotation when heal.log exceeds RUNNERKIT_MAX_LOG_BYTES
  local heal_log="${HOME}/Library/Logs/runnerkit/heal.log"
  local i=0
  while [ "$i" -lt 80 ]; do
    printf '0123456789abcdef0123456789abcdef0123456789abcdef line %s\n' "$i" >>"$heal_log"
    i=$((i + 1))
  done
  export RUNNERKIT_MAX_LOG_BYTES=500
  "$RUNNERKIT" heal >/dev/null
  [ -f "${heal_log}.1" ] || fail "oversized heal.log rotated to heal.log.1"

  "$RUNNERKIT" agent uninstall >/dev/null
  [ ! -f "$agent_plist" ] || fail "agent plist removed on uninstall"
  local rc=0
  "$RUNNERKIT" agent status >/dev/null 2>&1 || rc=$?
  assert_eq "1" "$rc" "agent status exits 1 after uninstall"

  # install.sh link and --uninstall
  local custom_bin="${TEST_ROOT}/custom-bin"
  "$INSTALL_SH" --bin-dir "$custom_bin" >/dev/null
  [ -L "${custom_bin}/runnerkit" ] || fail "install.sh creates runnerkit symlink"
  assert_contains "$("${custom_bin}/runnerkit" version)" "runnerkit 1.0.0" "linked runnerkit runs version"
  "$INSTALL_SH" --uninstall --bin-dir "$custom_bin" >/dev/null
  [ ! -e "${custom_bin}/runnerkit" ] || fail "install.sh --uninstall removes symlink"

  # Usage error -> exit 2
  rc=0
  "$RUNNERKIT" bogus-subcommand >/dev/null 2>&1 || rc=$?
  assert_eq "2" "$rc" "unknown subcommand exits 2"

  # Non-macOS -> exit 3
  export STUB_UNAME="Linux"
  rc=0
  "$RUNNERKIT" status >/dev/null 2>&1 || rc=$?
  assert_eq "3" "$rc" "non-macOS uname exits 3"
  unset STUB_UNAME

  # Missing required tool -> exit 3
  local partial_bin="${TEST_ROOT}/partial-bin"
  mkdir -p "$partial_bin"
  cp "${STUBS_DIR}/uname" "$partial_bin/uname"
  rc=0
  PATH="$partial_bin" "$RUNNERKIT" status >/dev/null 2>&1 || rc=$?
  assert_eq "3" "$rc" "missing required tool exits 3"

  pass "agent install/status/uninstall, log rotation, install.sh, and exit codes 2 & 3"
}

# ---------------------------------------------------------------------------
# 11. Doctor workflow sequence (resume -> pause -> heal -> doctor + summary)
# ---------------------------------------------------------------------------
test_workflow_sequence() {
  setup_env
  add_runner_fixture "actions.runner.acme-app.wf-1" "wf-1" "https://github.com/acme/app" "${TEST_ROOT}/wf1" 1 "511" "0"
  add_runner_fixture "actions.runner.acme-app.wf-2" "wf-2" "https://github.com/acme/app" "${TEST_ROOT}/wf2" 1 "512" "0"
  add_runner_fixture "actions.runner.acme-app.wf-3" "wf-3" "https://github.com/acme/app" "${TEST_ROOT}/wf3" 1 "" "1"

  # Start with wf-1 paused; job runs on wf-2 (RUNNER_NAME=wf-2), resumes wf-1, pauses wf-3? No:
  # Let's resume wf-1, pause wf-2 (self -> must refuse!), heal wf-3 (stopped -> idle), and run doctor.
  "$RUNNERKIT" pause wf-1 --reason "old pause" >/dev/null
  export RUNNER_NAME="wf-2"

  "$RUNNERKIT" resume wf-1 >/dev/null
  local self_pause_rc=0
  "$RUNNERKIT" pause wf-2 --now --reason "https://github.com/acme/app/actions/runs/1" >/dev/null 2>&1 || self_pause_rc=$?
  assert_eq "1" "$self_pause_rc" "workflow pause on self runner fails so workflow can report not done"

  "$RUNNERKIT" heal >/dev/null
  local summary_file="${TEST_ROOT}/step_summary.md"
  local wf_json
  wf_json=$("$RUNNERKIT" doctor --summary "$summary_file" --json)
  assert_valid_json "$wf_json" "workflow doctor JSON valid"
  if [ "$HAS_JQ" -eq 1 ]; then
    assert_eq "true" "$(jq_val "$wf_json" '.healthy')" "all three runners idle after resume + heal"
    assert_eq "idle" "$(jq_val "$wf_json" '.instances[] | select(.name=="wf-1") | .state')" "wf-1 resumed to idle"
    assert_eq "idle" "$(jq_val "$wf_json" '.instances[] | select(.name=="wf-3") | .state')" "wf-3 healed to idle"
  fi
  assert_contains "$(cat "$summary_file")" "| \`wf-1\` |" "step summary lists wf-1"
  unset RUNNER_NAME
  pass "doctor workflow sequence (resume -> pause self refusal -> heal -> doctor summary)"
}

printf 'Running runnerkit test suite...\n'
test_no_instances
test_all_base_states
test_bom_and_spaces
test_heal_actions
test_flapping_lifecycle
test_self_skip_and_dry_run
test_json_escaping_and_masking
test_pause_and_resume
test_doctor_checks
test_agent_install_and_exit_codes
test_workflow_sequence
printf 'All %s test groups passed.\n' "$PASS_COUNT"
