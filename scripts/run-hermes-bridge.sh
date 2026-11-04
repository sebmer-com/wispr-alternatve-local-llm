#!/bin/bash
# Model-only bridge. No request content or credentials belong in argv.
set -eu
if [ "$#" -ne 0 ]; then
    printf '%s\n' '{"ok":false,"error":"The Hermes bridge accepts JSON on stdin only; no arguments are allowed."}'
    exit 1
fi
SCRIPT_DIR="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)"
PYTHON="$(command -v python3 || true)"
if [ -z "$PYTHON" ] || [ ! -x "$PYTHON" ]; then
    printf '%s\n' '{"ok":false,"error":"Python 3.9 or later is required to discover the Hermes runtime."}'
    exit 1
fi
# exec keeps the bridge at the PID owned by the Swift caller. Python discovers
# Hermes' supported runtime argv and execs it without a shell or agent process.
exec "$PYTHON" -I "$SCRIPT_DIR/hermes_command_bridge.py" --launch
