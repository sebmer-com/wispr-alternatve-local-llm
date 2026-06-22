#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_BIN="${ROOT_DIR}/app/.build/debug/fluid-push-to-talk"

if [[ "${LOCAL_AUDIO_VISIBLE_TERMINAL:-0}" != "1" ]]; then
  quoted_root="$(printf "%q" "${ROOT_DIR}")"
  quoted_args=""
  for arg in "$@"; do
    quoted_args+=" $(printf "%q" "${arg}")"
  done
  terminal_command="cd ${quoted_root} && LOCAL_AUDIO_VISIBLE_TERMINAL=1 ./restart.sh${quoted_args}"
  escaped_command="${terminal_command//\\/\\\\}"
  escaped_command="${escaped_command//\"/\\\"}"
  osascript <<EOF
tell application "Terminal"
  activate
  do script "${escaped_command}"
end tell
EOF
  exit 0
fi

"${ROOT_DIR}/stop.sh"

if [[ ! -x "${APP_BIN}" ]]; then
  echo "Missing app binary: ${APP_BIN}" >&2
  echo "Building it first..." >&2
  (cd "${ROOT_DIR}/app" && swift build)
fi

exec "${ROOT_DIR}/launch.sh" "$@"
