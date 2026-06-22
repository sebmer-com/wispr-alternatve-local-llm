#!/usr/bin/env bash
set -euo pipefail

pkill -f "/app/.build/debug/fluid-push-to-talk" 2>/dev/null || true
pkill -f "Fluid Push To Talk" 2>/dev/null || true
