#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${HOME}/.config/fluid-push-to-talk"
BIN_DIR="${HOME}/.local/bin"
APP_BIN="${ROOT_DIR}/app/.build/debug/fluid-push-to-talk"

RESET_STATE=0
RUN_SETUP=0
NO_LAUNCH=0
PRESERVE_STATE=0

usage() {
  cat <<EOF
Usage:
  ./install.sh [--reset-state] [--setup] [--no-launch] [--preserve-state]

Options:
  --reset-state     Remove user config, support files, and local .env before writing defaults.
  --setup           Start the interactive onboarding wizard after build.
  --no-launch       Do not start the voice agent after setup.
  --preserve-state  Keep existing user config and .env.
  --help            Show this help.
EOF
}

info() {
  printf '• %s\n' "$*" >&2
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset-state)
      RESET_STATE=1
      shift
      ;;
    --setup)
      RUN_SETUP=1
      shift
      ;;
    --no-launch)
      NO_LAUNCH=1
      shift
      ;;
    --preserve-state)
      PRESERVE_STATE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || fail "fluid-push-to-talk currently supports macOS only."
command -v swift >/dev/null 2>&1 || fail "missing required command: swift"

if [[ "${RESET_STATE}" == "1" && "${PRESERVE_STATE}" == "1" ]]; then
  fail "--reset-state and --preserve-state cannot be used together."
fi

mkdir -p "${CONFIG_DIR}" "${BIN_DIR}"

if [[ "${RESET_STATE}" == "1" ]]; then
  info "Resetting local config state at ${CONFIG_DIR}"
  rm -f \
    "${CONFIG_DIR}/config.json" \
    "${CONFIG_DIR}/promptConfig.json" \
    "${CONFIG_DIR}/textReplacements.json" \
    "${CONFIG_DIR}/.env"
fi

info "Building Swift package"
(cd "${ROOT_DIR}/app" && swift build)

ln -sf "${APP_BIN}" "${BIN_DIR}/fluid-push-to-talk"

if [[ "${PRESERVE_STATE}" == "0" && ! -f "${CONFIG_DIR}/config.json" ]]; then
  "${APP_BIN}" config reset --yes
fi

if [[ "${RUN_SETUP}" == "1" ]]; then
  "${APP_BIN}" setup
  "${APP_BIN}" config doctor || true
fi

cat <<EOF
Installed:
  Binary: ${APP_BIN}
  Symlink: ${BIN_DIR}/fluid-push-to-talk
  Config: ${CONFIG_DIR}/config.json

Run:
  fluid-push-to-talk
  fluid-push-to-talk setup
  fluid-push-to-talk config show
  fluid-push-to-talk config doctor
EOF

if [[ "${RUN_SETUP}" == "1" && "${NO_LAUNCH}" == "0" ]]; then
  info "Starting voice agent"
  "${ROOT_DIR}/restart.sh"
fi
