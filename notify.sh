#!/usr/bin/env bash
# herdr-notify (WSL -> Windows): raise a Windows 11 toast when an agent needs you.
#
# WSL-native adaptation of the upstream Windows plugin. herdr runs as the Linux
# binary inside WSL, so the status query/diff happens here in bash; we only cross
# into Windows (via powershell.exe) for the actual toast.
#
# Wired to the `pane.agent_status_changed` event. Rather than trust the event
# payload, it reads `herdr pane list` for every agent pane's status and diffs it
# against the last-seen status (a JSON state file), notifying on exactly:
#
#   working -> done | idle   -> "Turn finished"
#   working -> blocked       -> "Needs input"
#
# `--test` fires one sample toast to confirm delivery (Focus Assist off, notifications on).
set -euo pipefail

HERDR_BIN="${HERDR_BIN_PATH:-herdr}"
STATE_DIR="${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}}"
# Plugin state directory is shared across named Herdr sessions. Scope by the
# session socket because pane IDs (e.g. w1:p1) repeat across sessions.
SESSION_KEY="${HERDR_SOCKET_PATH:-${HERDR_SESSION:-default}}"
SESSION_HASH=$(printf '%s' "$SESSION_KEY" | sha256sum | cut -c 1-16)
STATE_PATH="$STATE_DIR/agent-status-$SESSION_HASH.json"
LOCK_PATH="$STATE_PATH.lock"
MIN_DONE_SECONDS="${HERDR_NOTIFY_MIN_SECONDS:-30}"

PS="${WINDIR:+$WINDIR/System32/WindowsPowerShell/v1.0/powershell.exe}"
PS="${PS:-powershell.exe}"

# Raise a native Windows toast. Args: title, message. Text is passed as base64 to
# dodge any quoting/encoding hazard crossing the WSL->Windows boundary.
show_toast() {
  local title_b64 msg_b64
  title_b64=$(printf '%s' "$1" | base64 -w0)
  msg_b64=$(printf '%s' "$2" | base64 -w0)
  "$PS" -NoProfile -ExecutionPolicy Bypass -Command "
\$title = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$title_b64'))
\$msg   = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$msg_b64'))
\$appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
\$xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
\$t = \$xml.GetElementsByTagName('text')
[void]\$t.Item(0).AppendChild(\$xml.CreateTextNode(\$title))
[void]\$t.Item(1).AppendChild(\$xml.CreateTextNode(\$msg))
\$toast = [Windows.UI.Notifications.ToastNotification]::new(\$xml)
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(\$appId).Show(\$toast)
" >/dev/null 2>&1
}

if [[ "${1:-}" == "--test" || "${1:-}" == "-Test" ]]; then
  show_toast 'herdr-notify' 'Test notification - setup OK'
  exit 0
fi

# Serialize read/compare/write to prevent concurrent event handlers from
# racing and sending duplicate notifications.
mkdir -p "$STATE_DIR"
exec 9>"$LOCK_PATH"
flock 9

current=$("$HERDR_BIN" pane list 2>/dev/null | jq -c '
  [.result.panes[] | select(.agent != null and .agent != "")
    | {key: .pane_id, value: {status: (.agent_status // ""), agent: (.agent // ""), workspace: (.workspace_id // "")}}]
  | from_entries')
prev='{}'
[[ ! -f "$STATE_PATH" ]] || prev=$(cat "$STATE_PATH")
now=$(date +%s)

# Notify immediately when blocked. For completed turns, suppress short turns.
# Preserve the first working timestamp while a turn remains active.
notifs=$(jq -rn --argjson prev "$prev" --argjson cur "$current" --argjson now "$now" --argjson threshold "$MIN_DONE_SECONDS" '
  $cur | to_entries[] | . as $e
  | ($prev[$e.key] // {}) as $before
  | select($before.status == "working")
  | (if $e.value.status == "blocked" then "blocked"
     elif (["done","idle"] | index($e.value.status)) and ($now - ($before.started // $now) >= $threshold) then "done"
     else empty end) as $kind
  | [$e.value.agent, $e.value.workspace, $kind] | @tsv')

next=$(jq -n --argjson prev "$prev" --argjson cur "$current" --argjson now "$now" '
  $cur | with_entries(.key as $id | .value |=
    {status: .status, started: (if .status == "working" then
      (if $prev[$id].status == "working" then ($prev[$id].started // $now) else $now end)
      else null end)})')
tmp=$(mktemp "$STATE_PATH.tmp.XXXXXX")
printf '%s\n' "$next" > "$tmp"
mv -f "$tmp" "$STATE_PATH"
flock -u 9

# Resolve a workspace id to a human label, falling back to the id.
workspace_label() {
  local id="$1" label
  [[ -z "$id" ]] && { echo ""; return; }
  label=$("$HERDR_BIN" workspace get "$id" 2>/dev/null \
    | jq -r '.result.workspace | (.label // "") as $l | (.number|tostring) as $n
             | if ($l != "" and $l != $n) then $l else "" end' 2>/dev/null || echo "")
  [[ -n "$label" ]] && echo "$label" || echo "$id"
}

if [[ -n "$notifs" ]]; then
  while IFS=$'\t' read -r agent workspace kind; do
    [[ -z "$agent" ]] && continue
    label=$(workspace_label "$workspace")
    who="$agent"
    [[ -n "$label" ]] && who="$agent · $label"
    body="Turn finished"
    [[ "$kind" == "blocked" ]] && body="Needs input"
    show_toast "$who" "$body"
  done <<< "$notifs"
fi

# State is persisted atomically before toast delivery.
