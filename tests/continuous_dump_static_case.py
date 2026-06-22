#!/usr/bin/env python3
import json
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
APP_RUNTIME = REPO_ROOT / "app" / "Sources" / "AppRuntime.swift"
APP_CONFIG = REPO_ROOT / "app" / "Sources" / "Config" / "AppConfig.swift"
OPTIONS = REPO_ROOT / "app" / "Sources" / "CLI" / "Options.swift"
CONFIG_JSON = REPO_ROOT / "config" / "config.json"


def main() -> int:
    runtime_source = APP_RUNTIME.read_text(encoding="utf-8")
    config_source = APP_CONFIG.read_text(encoding="utf-8")
    options_source = OPTIONS.read_text(encoding="utf-8")
    config = json.loads(CONFIG_JSON.read_text(encoding="utf-8"))
    continuous_dump = config.get("continuous_dump", {})

    checks = [
        (
            continuous_dump.get("enabled") is False,
            "continuous_dump.enabled must default to false for Simple Setup",
        ),
        (
            "struct ContinuousDumpConfig" in config_source,
            "ContinuousDumpConfig must decode continuous dump settings",
        ),
        (
            'case continuousDump = "continuous_dump"' in config_source,
            "AppConfig must load the continuous_dump config object",
        ),
        (
            'case "go", "record go"' in runtime_source,
            "terminal command reader must support go",
        ),
        (
            'case "stop", "record stop"' in runtime_source,
            "terminal command reader must support stop",
        ),
        (
            '"dump start"' not in runtime_source and '"dump stop"' not in runtime_source,
            "terminal command reader must not expose dump-prefixed commands",
        ),
        (
            '"start"' not in runtime_source
            and '"record start"' not in runtime_source
            and '"recording start"' not in runtime_source,
            "terminal command reader must not expose start aliases",
        ),
        (
            "TerminalCommandReader" in runtime_source,
            "app must install a terminal command reader",
        ),
        (
            "recorder.start(usesWatchdog: false)" in runtime_source,
            "terminal continuous dump must record until stop without the push-to-talk watchdog",
        ),
        (
            "continuous dump stopped; transcribing..." in runtime_source,
            "terminal continuous dump must transcribe only after stop",
        ),
        (
            "--continuous-dump-interval" not in options_source,
            "CLI must not expose a chunk interval for stop-triggered continuous dump",
        ),
        (
            "type go and stop" in options_source,
            "CLI help must document terminal continuous dump commands",
        ),
        (
            "Press Tab to autocomplete" in runtime_source
            and "applyCompletion(to:" in runtime_source
            and "readCommandLine()" in runtime_source,
            "terminal command reader must support Tab autocomplete",
        ),
        (
            "readLine()" not in runtime_source,
            "terminal command reader must not use readLine because it cannot autocomplete",
        ),
        (
            ".bySentences" not in runtime_source,
            "continuous dump must not split or dump partial sentences",
        ),
    ]

    failed = False
    for passed, message in checks:
        if not passed:
            print(f"continuous dump regression: {message}", file=sys.stderr)
            failed = True

    if failed:
        return 1

    print("continuous dump static checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
