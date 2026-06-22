#!/usr/bin/env bash
set -euo pipefail

DEFAULT_GITHUB_REPO="sebmer-com/wispr-alternatve-local-llm"
DEFAULT_GITHUB_REF="main"

GITHUB_REPO="${LOCAL_AUDIO_GITHUB_REPO:-$DEFAULT_GITHUB_REPO}"
GITHUB_REF="${LOCAL_AUDIO_GITHUB_REF:-$DEFAULT_GITHUB_REF}"
RAW_BASE_URL="${LOCAL_AUDIO_GITHUB_RAW_BASE_URL:-https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_REF}}"
SOURCE_DIR="${LOCAL_AUDIO_SOURCE_DIR:-$HOME/.local/share/fluid-push-to-talk/source}"
PRINT_COMMAND=0
PASS_THROUGH_ARGS=()
TMP_DIR=""

usage() {
  cat <<EOF
Usage:
  curl -fsSL ${RAW_BASE_URL}/github-install.sh | bash -s -- --reset-state --setup

Options:
  --print-command  Print the resolved install command without running it.
  --help           Show this help.

All other arguments are passed to install.sh.

Environment:
  LOCAL_AUDIO_GITHUB_REPO          Override owner/repo. Default: ${DEFAULT_GITHUB_REPO}
  LOCAL_AUDIO_GITHUB_REF           Override ref. Default: ${DEFAULT_GITHUB_REF}
  LOCAL_AUDIO_GITHUB_RAW_BASE_URL  Override raw GitHub base URL.
  LOCAL_AUDIO_SOURCE_DIR           Override clone/update directory. Default: ${SOURCE_DIR}
  LOCAL_AUDIO_INSTALL_STDIN        Set to inherit to keep piped stdin instead of /dev/tty.
EOF
}

info() {
  printf '• %s\n' "$*" >&2
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

quote_args() {
  printf '%q ' "$@"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --print-command)
      PRINT_COMMAND=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      PASS_THROUGH_ARGS+=("$1")
      shift
      ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || fail "fluid-push-to-talk currently supports macOS only."
command -v git >/dev/null 2>&1 || fail "missing required command: git"
command -v swift >/dev/null 2>&1 || fail "missing required command: swift"
command -v curl >/dev/null 2>&1 || fail "missing required command: curl"

INSTALL_CMD=(/bin/bash "${SOURCE_DIR}/install.sh")
if [[ "${#PASS_THROUGH_ARGS[@]}" -gt 0 ]]; then
  INSTALL_CMD+=("${PASS_THROUGH_ARGS[@]}")
fi

if [[ "${PRINT_COMMAND}" == "1" ]]; then
  quote_args "${INSTALL_CMD[@]}"
  printf '\n'
  exit 0
fi

mkdir -p "$(dirname "${SOURCE_DIR}")"
if [[ -d "${SOURCE_DIR}/.git" ]]; then
  info "Updating ${GITHUB_REPO}@${GITHUB_REF} in ${SOURCE_DIR}"
  git -C "${SOURCE_DIR}" fetch --depth 1 origin "${GITHUB_REF}"
  git -C "${SOURCE_DIR}" checkout -q FETCH_HEAD
else
  rm -rf "${SOURCE_DIR}"
  info "Cloning ${GITHUB_REPO}@${GITHUB_REF} into ${SOURCE_DIR}"
  git clone --depth 1 --branch "${GITHUB_REF}" "https://github.com/${GITHUB_REPO}.git" "${SOURCE_DIR}"
fi

if [[ "${LOCAL_AUDIO_INSTALL_STDIN:-tty}" != "inherit" && -r /dev/tty ]]; then
  exec "${INSTALL_CMD[@]}" < /dev/tty
fi

exec "${INSTALL_CMD[@]}"
