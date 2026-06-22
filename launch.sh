#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_BIN="${ROOT_DIR}/app/.build/debug/fluid-push-to-talk"

if [[ ! -x "${APP_BIN}" ]]; then
  echo "Missing app binary: ${APP_BIN}" >&2
  echo "Build it first with: cd ${ROOT_DIR}/app && swift build" >&2
  exit 1
fi

export LOCALPTT_COLOR="${LOCALPTT_COLOR:-1}"
exec "${APP_BIN}" "$@"
