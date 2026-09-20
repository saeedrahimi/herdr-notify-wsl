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
STATE_PATH="$STATE_DIR/agent-status.json"
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

# Current agent panes -> JSON object { pane_id: {status, agent, workspace} }
current=$("$HERDR_BIN" pane list 2>/dev/null | jq -c '
  [.result.panes[] | select(.agent != null and .agent != "")
    | {key: .pane_id, value: {status: (.agent_status // ""), agent: (.agent // ""), workspace: (.workspace_id // "")}}]
  | from_entries')

# Previous status map { pane_id: status }; empty object if no state yet.
prev="{}"
[[ -f "$STATE_PATH" ]] && prev=$(cat "$STATE_PATH" 2>/dev/null || echo '{}')

# Notifications: only a working -> rest edge fires. Emits TSV: agent<TAB>workspace<TAB>kind
#
# The parentheses around `if ... end` are load-bearing, not cosmetic: `as` binds a term, and an
# `if ... end` expression is not one, so `if ... end as $kind` is a syntax error on jq 1.6 that
# aborts the whole hook before it can ever persist state. jaq accepts both forms, which is how the
# bare form can survive in a shell whose `jq` is really jaq.
notifs=$(jq -rn --argjson prev "$prev" --argjson cur "$current" '
  $cur | to_entries[]
  | . as $e
  | ($prev[$e.key] // "") as $before
  | select($before == "working")
  | (if (["done","idle"] | index($e.value.status)) then "done"
     elif $e.value.status == "blocked" then "blocked"
     else empty end) as $kind
  | [$e.value.agent, $e.value.workspace, $kind] | @tsv')

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

# Persist current statuses as { pane_id: status } for the next diff.
mkdir -p "$STATE_DIR"
echo "$current" | jq -c 'map_values(.status)' > "$STATE_PATH"
