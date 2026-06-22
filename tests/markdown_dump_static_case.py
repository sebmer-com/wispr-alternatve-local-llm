#!/usr/bin/env python3
import json
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
APP_CONFIG = REPO_ROOT / "app" / "Sources" / "Config" / "AppConfig.swift"
CONFIG_JSON = REPO_ROOT / "config" / "config.json"


def main() -> int:
    source = APP_CONFIG.read_text(encoding="utf-8")
    config = json.loads(CONFIG_JSON.read_text(encoding="utf-8"))
    markdown_file = config["dump"]["markdown_file"]

    checks = [
        (
            "Daily Notes/YYYY-MM-DD.md" in markdown_file,
            "default dump target must write to the Obsidian Daily Notes date template",
        ),
        (
            "Inbox.md" not in markdown_file,
            "default dump target must not point at the old Inbox.md path",
        ),
        (
            'replacingOccurrences(of: "YYYY-MM-DD"' in source,
            "DumpConfig must resolve the user-facing YYYY-MM-DD date placeholder",
        ),
        (
            'replacingOccurrences(of: "yyyy-MM-dd"' in source,
            "DumpConfig must resolve the Swift-style yyyy-MM-dd date placeholder",
        ),
        (
            'formatter.dateFormat = "yyyy-MM-dd"' in source,
            "DumpConfig must format daily note names as yyyy-MM-dd",
        ),
    ]

    failed = False
    for passed, message in checks:
        if not passed:
            print(f"markdown dump regression: {message}", file=sys.stderr)
            failed = True

    if failed:
        return 1

    print("markdown dump static checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
