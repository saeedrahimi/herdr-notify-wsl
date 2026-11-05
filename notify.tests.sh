#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/System32/WindowsPowerShell/v1.0" "$tmp/state"
cat > "$tmp/mock-herdr" <<'EOF'
#!/bin/sh
case "$1 $2" in
  'pane list') cat "$MOCK_PANES" ;;
  'workspace get') printf '{"result":{"workspace":{"label":"Test Project","number":1}}}\n' ;;
  *) exit 1 ;;
esac
EOF
cat > "$tmp/System32/WindowsPowerShell/v1.0/powershell.exe" <<'EOF'
#!/bin/sh
printf 'toast\n' >> "$MOCK_TOAST_LOG"
EOF
chmod +x "$tmp/mock-herdr" "$tmp/System32/WindowsPowerShell/v1.0/powershell.exe"
export HERDR_BIN_PATH="$tmp/mock-herdr" HERDR_PLUGIN_STATE_DIR="$tmp/state" WINDIR="$tmp"
export MOCK_PANES="$tmp/panes.json" MOCK_TOAST_LOG="$tmp/toasts.log"
run_state() {
  printf '{"result":{"panes":[{"pane_id":"w1:p1","agent":"codex","agent_status":"%s","workspace_id":"w1"}]}}\n' "$1" > "$MOCK_PANES"
  bash "$root/notify.sh"
}
count() { if [[ -f "$MOCK_TOAST_LOG" ]]; then wc -l < "$MOCK_TOAST_LOG"; else echo 0; fi; }
assert_count() { [[ $(count) -eq "$1" ]] || { echo "Expected $1 notifications, got $(count)" >&2; exit 1; }; }
export HERDR_SOCKET_PATH="$tmp/session-a/herdr.sock"
state_file() { find "$tmp/state" -name 'agent-status-*.json' -type f | head -1; }
age_working() {
  local f="$1" output
  output=$(mktemp)
  jq 'with_entries(if .value.status == "working" then .value.started -= 35 else . end)' "$f" > "$output"
  mv "$output" "$f"
}
run_state working; assert_count 0
run_state done; assert_count 0 # short completion suppressed
run_state working; assert_count 0
age_working "$(state_file)"
run_state done; assert_count 1
run_state done; assert_count 1
run_state working; assert_count 1
run_state blocked; assert_count 2 # blocked immediately
run_state blocked; assert_count 2
run_state working; assert_count 2
age_working "$(state_file)"
run_state idle; assert_count 3
# Same pane ID on another Herdr server must have an independent state file.
export HERDR_SOCKET_PATH="$tmp/session-b/herdr.sock"
run_state done; assert_count 3
run_state working; assert_count 3
key=$(printf '%s' "$HERDR_SOCKET_PATH" | sha256sum | cut -c 1-16)
age_working "$tmp/state/agent-status-$key.json"
run_state done; assert_count 4
[[ $(find "$tmp/state" -name 'agent-status-*.json' -type f | wc -l) -eq 2 ]]
printf 'PASS: 30s threshold, done/blocked/idle, de-duplication, session isolation\n'
