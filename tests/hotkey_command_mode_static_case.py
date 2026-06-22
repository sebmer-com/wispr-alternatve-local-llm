#!/usr/bin/env python3
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
APP_RUNTIME = REPO_ROOT / "app" / "Sources" / "AppRuntime.swift"


def main() -> int:
    source = APP_RUNTIME.read_text(encoding="utf-8")
    checks = [
        (
            "private let commandModeGrace: TimeInterval = 0.15",
            "hotkey controller must debounce command-mode entry",
        ),
        (
            "private var pendingContinuation: DispatchWorkItem?",
            "hotkey controller must track pending command-mode confirmation",
        ),
        (
            "scheduleContinuationConfirmation(for: activeAction)",
            "continuation key state must schedule confirmation instead of switching immediately",
        ),
        (
            "stateQueue.asyncAfter(deadline: .now() + commandModeGrace, execute: workItem)",
            "command-mode confirmation must wait for the grace period",
        ),
        (
            "cancelPendingContinuation()",
            "plain release path must cancel pending command-mode confirmation",
        ),
        (
            "confirmContinuation(for action: HotkeyAction)",
            "confirmed command-mode transition must be isolated",
        ),
    ]

    failed = False
    for needle, message in checks:
        if needle not in source:
            print(f"hotkey command-mode regression: {message}", file=sys.stderr)
            failed = True

    immediate_transition = """
            if continuation {
                guard let informationURL = recorder.stop() else {
"""
    if immediate_transition in source:
        print(
            "hotkey command-mode regression: continuation must not immediately stop information recording",
            file=sys.stderr,
        )
        failed = True

    if failed:
        return 1

    print("hotkey command-mode static checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
