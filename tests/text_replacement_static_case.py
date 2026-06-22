#!/usr/bin/env python3
import json
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    config = json.loads((REPO_ROOT / "config" / "config.json").read_text(encoding="utf-8"))
    replacements_path = REPO_ROOT / "config" / config.get("text_replacements_file", "")
    if replacements_path.name != "textReplacements.json":
        print("text replacement regression: config must point at textReplacements.json", file=sys.stderr)
        return 1
    if not replacements_path.exists():
        print(f"text replacement regression: missing {replacements_path}", file=sys.stderr)
        return 1

    replacements = json.loads(replacements_path.read_text(encoding="utf-8"))
    if replacements.get("enabled") is not True:
        print("text replacement regression: replacements must be enabled by default", file=sys.stderr)
        return 1
    if replacements.get("replacements", {}).get("Dominic") != "Dominik":
        print("text replacement regression: Dominic -> Dominik default replacement is missing", file=sys.stderr)
        return 1

    app_config = (REPO_ROOT / "app" / "Sources" / "Config" / "AppConfig.swift").read_text(
        encoding="utf-8"
    )
    replacement_source = (
        REPO_ROOT / "app" / "Sources" / "Config" / "TextReplacementConfig.swift"
    ).read_text(encoding="utf-8")
    runtime_source = (REPO_ROOT / "app" / "Sources" / "AppRuntime.swift").read_text(encoding="utf-8")

    required = [
        ("case textReplacementsFile = \"text_replacements_file\"", app_config),
        ("TextReplacementConfig.load", app_config),
        ("final class TextReplacementService", replacement_source),
        ("replacementsByNormalizedWord", replacement_source),
        ("for scalar in text.unicodeScalars", replacement_source),
        ("NSRegularExpression", replacement_source),
        ("textReplacer.rewrite(text)", runtime_source),
        ("transcribeAndRewrite(url:", runtime_source),
    ]
    for needle, source in required:
        if needle == "NSRegularExpression":
            if needle in source:
                print("text replacement regression: replacement path must not use regex", file=sys.stderr)
                return 1
            continue
        if needle not in source:
            print(f"text replacement regression: missing {needle}", file=sys.stderr)
            return 1

    print("text replacement static checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
