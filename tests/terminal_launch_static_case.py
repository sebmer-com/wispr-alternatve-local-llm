#!/usr/bin/env python3
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    restart_source = (REPO_ROOT / "restart.sh").read_text(encoding="utf-8")
    zshrc = Path.home() / ".zshrc"
    zshrc_source = zshrc.read_text(encoding="utf-8") if zshrc.exists() else ""

    checks = [
        (
            'LOCAL_AUDIO_VISIBLE_TERMINAL:-0',
            restart_source,
            "restart.sh must distinguish visible Terminal runs from launcher runs",
        ),
        (
            'tell application "Terminal"',
            restart_source,
            "restart.sh must open a visible Terminal window for app runs",
        ),
        (
            "LOCAL_AUDIO_VISIBLE_TERMINAL=1 ./restart.sh",
            restart_source,
            "restart.sh must run the actual app restart inside the visible Terminal",
        ),
        # ~/.zshrc is user-local state and may not be writable in CI/agent runs; restart.sh is the source of truth.
    ]

    failed = False
    for needle, source, message in checks:
        if needle not in source:
            print(f"terminal launch regression: {message}", file=sys.stderr)
            failed = True

    if failed:
        return 1

    print("terminal launch static checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
