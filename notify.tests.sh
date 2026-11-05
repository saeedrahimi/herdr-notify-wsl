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
run_state working; assert_count 0
run_state done; assert_count 1
run_state done; assert_count 1
run_state working; assert_count 1
run_state blocked; assert_count 2
run_state blocked; assert_count 2
run_state working; assert_count 2
run_state idle; assert_count 3
printf 'PASS: completed, blocked, idle, and duplicate suppression\n'
