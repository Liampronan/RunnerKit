#!/bin/bash
# Integration test on a real macOS host exercising native /bin/bash 3.2,
# /usr/bin/plutil, and real launchctl (gui/<uid>) with a dummy runner service.

set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
  printf 'Skipping macos_launchd_test.sh: host is %s, not Darwin.\n' "$(uname -s)"
  exit 0
fi

REPO_ROOT=$(cd -P "$(dirname "$0")/.." && pwd)
RUNNERKIT="${REPO_ROOT}/bin/runnerkit"
UID_NUM=$(id -u)
DUMMY_LABEL="actions.runner.example-repo.ci-dummy-1"

if ! launchctl print "gui/${UID_NUM}" >/dev/null 2>&1; then
  printf 'ERROR: gui/%s launchd domain is not active on this macOS runner.\n' "$UID_NUM" >&2
  exit 1
fi

FAKE_HOME=$(mktemp -d "${TMPDIR:-/tmp}/rk-macos-it.XXXXXX")
DUMMY_DIR="${FAKE_HOME}/runner-instance"
LOG_DIR="${FAKE_HOME}/Library/Logs/${DUMMY_LABEL}"
PLIST_PATH="${FAKE_HOME}/Library/LaunchAgents/${DUMMY_LABEL}.plist"

cleanup() {
  launchctl bootout "gui/${UID_NUM}/${DUMMY_LABEL}" >/dev/null 2>&1 || true
  launchctl enable "gui/${UID_NUM}/${DUMMY_LABEL}" >/dev/null 2>&1 || true
  rm -rf "$FAKE_HOME"
}
trap cleanup EXIT

mkdir -p "${DUMMY_DIR}/_diag" "$LOG_DIR" "${FAKE_HOME}/Library/LaunchAgents"

# Write BOM-prefixed .runner metadata file just like actions/runner IOUtil.SaveObject.
BOM=$(printf '\357\273\277')
cat >"${DUMMY_DIR}/.runner" <<EOF
${BOM}{
  "agentId": 99,
  "agentName": "ci-dummy-1",
  "gitHubUrl": "https://github.com/example/repo",
  "workFolder": "_work"
}
EOF

# Dummy runsvc.sh controlled via ${DUMMY_DIR}/mode ("exit1" or "sleep").
cat >"${DUMMY_DIR}/runsvc.sh" <<'EOF'
#!/bin/bash
DIR=$(cd -P "$(dirname "$0")" && pwd)
MODE=$(cat "${DIR}/mode" 2>/dev/null || printf 'sleep')
if [ "$MODE" = "exit1" ]; then
  printf 'Runner listener exit with terminated error, stop the service, no retry needed.\n' >&2
  exit 1
fi
trap 'exit 0' TERM INT
sleep 120 &
wait $!
EOF
chmod +x "${DUMMY_DIR}/runsvc.sh"

cat >"$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>${DUMMY_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
      <string>${DUMMY_DIR}/runsvc.sh</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${DUMMY_DIR}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/stderr.log</string>
  </dict>
</plist>
EOF

plutil -lint "$PLIST_PATH" >/dev/null

export HOME="$FAKE_HOME"
unset RUNNER_NAME

assert_json_field() {
  local json="$1"
  local expr="$2"
  local expected="$3"
  local msg="$4"
  local actual
  actual=$(printf '%s\n' "$json" | jq -r "$expr")
  if [ "$actual" != "$expected" ]; then
    printf 'FAIL: %s (expected=%s actual=%s)\nJSON:\n%s\n' "$msg" "$expected" "$actual" "$json" >&2
    exit 1
  fi
  printf '  ok - %s\n' "$msg"
}

printf 'Running real macOS launchd integration test (gui/%s)...\n' "$UID_NUM"

# 1. Before bootstrap: service is unloaded.
rc=0
j_unloaded=$(/bin/bash "$RUNNERKIT" status --json) || rc=$?
[ "$rc" -eq 1 ] || { printf 'Expected exit 1 for unloaded\n' >&2; exit 1; }
assert_json_field "$j_unloaded" '.instances[0].state' 'unloaded' 'unbootstrapped plist detected as unloaded'

wait_for_stopped_exit1() {
  local target="gui/${UID_NUM}/${DUMMY_LABEL}"
  local attempt=0
  local out=""
  while [ "$attempt" -lt 40 ]; do
    if out=$(launchctl print "$target" 2>&1); then
      if ! printf '%s\n' "$out" | grep -E -q '^[[:space:]]*pid[[:space:]]*=' \
         && printf '%s\n' "$out" | grep -E -q 'last exit code = 1([[:space:]]|$)'; then
        return 0
      fi
    fi
    sleep 0.25
    attempt=$((attempt + 1))
  done
  printf 'FAIL: timed out waiting for %s to stay loaded with no PID and last exit code = 1.\n' "$target" >&2
  printf 'launchctl print output:\n%s\n' "$out" >&2
  launchctl list | grep -F "$DUMMY_LABEL" >&2 || true
  exit 1
}

wait_for_unloaded() {
  local target="gui/${UID_NUM}/${DUMMY_LABEL}"
  local attempt=0
  while [ "$attempt" -lt 40 ]; do
    if ! launchctl print "$target" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
    attempt=$((attempt + 1))
  done
  printf 'FAIL: timed out waiting for %s to unload.\n' "$target" >&2
  launchctl print "$target" >&2 || true
  exit 1
}

# 2. Bootstrap with mode=exit1 -> service loads, exits 1, stays stopped.
printf 'exit1' >"${DUMMY_DIR}/mode"
launchctl bootstrap "gui/${UID_NUM}" "$PLIST_PATH"
wait_for_stopped_exit1

rc=0
j_stopped=$(/bin/bash "$RUNNERKIT" status --json) || rc=$?
[ "$rc" -eq 1 ] || { printf 'Expected exit 1 for stopped\n' >&2; exit 1; }
assert_json_field "$j_stopped" '.instances[0].state' 'stopped' 'crashed service detected as stopped'
assert_json_field "$j_stopped" '.instances[0].last_exit' '1' 'stopped service reports last_exit=1'

# 3. Switch mode=sleep and run `runnerkit heal` -> kickstart brings it up to idle.
printf 'sleep' >"${DUMMY_DIR}/mode"
j_healed=$(/bin/bash "$RUNNERKIT" heal --json)
assert_json_field "$j_healed" '.instances[0].state' 'idle' 'heal kickstart brings stopped service to idle'
assert_json_field "$j_healed" '.instances[0].action' 'restarted' 'heal records action=restarted'

# 4. Manually bootout -> unloaded -> `runnerkit heal` bootstraps it back to idle.
launchctl bootout "gui/${UID_NUM}/${DUMMY_LABEL}"
wait_for_unloaded
j_reloaded=$(/bin/bash "$RUNNERKIT" heal --json)
assert_json_field "$j_reloaded" '.instances[0].state' 'idle' 'heal bootstrap brings unloaded service to idle'
assert_json_field "$j_reloaded" '.instances[0].action' 'loaded' 'heal records action=loaded'

# 5. Pause -> disables and boots out; heal leaves it down; resume -> enables and bootstraps.
j_paused=$(/bin/bash "$RUNNERKIT" pause ci-dummy-1 --reason "ci launchd test" --json)
assert_json_field "$j_paused" '.instances[0].state' 'paused' 'pause puts real service into paused state'
assert_json_field "$j_paused" '.healthy' 'true' 'paused runner keeps status healthy'

j_heal_paused=$(/bin/bash "$RUNNERKIT" heal --json)
assert_json_field "$j_heal_paused" '.instances[0].state' 'paused' 'heal leaves paused service down'
assert_json_field "$j_heal_paused" '.instances[0].action' 'none' 'heal takes no action on down paused service'

j_resumed=$(/bin/bash "$RUNNERKIT" resume ci-dummy-1 --json)
assert_json_field "$j_resumed" '.instances[0].state' 'idle' 'resume re-enables and bootstraps service to idle'
assert_json_field "$j_resumed" '.instances[0].action' 'resumed' 'resume records action=resumed'

printf 'All real macOS launchd integration checks passed.\n'
