#!/usr/bin/env python3
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
APP_RUNTIME = REPO_ROOT / "app" / "Sources" / "AppRuntime.swift"


def main() -> int:
    source = APP_RUNTIME.read_text(encoding="utf-8")
    checks = [
        (
            "let textToPaste = Self.withTrailingSpace(text)",
            "paste path must format text before writing to the pasteboard",
        ),
        (
            "pasteboard.setString(textToPaste, forType: .string)",
            "pasteboard must receive the formatted text",
        ),
        (
            "static func withTrailingSpace(_ text: String) -> String",
            "paste formatter must be explicit and testable",
        ),
        (
            "guard let last = text.last else",
            "paste formatter must handle empty text",
        ),
        (
            "return text + \" \"",
            "paste formatter must append a trailing space for every pasted text",
        ),
        (
            "last.isWhitespace",
            "paste formatter must avoid duplicating existing whitespace",
        ),
    ]
    forbidden = [
        "withSpaceAfterLastSentencePunctuation",
        'text.lastIndex(where: { ".?".contains($0) })',
        "formatted.insert(\" \", at:",
    ]

    failed = False
    for needle, message in checks:
        if needle not in source:
            print(f"paste spacing regression: {message}", file=sys.stderr)
            failed = True
    for needle in forbidden:
        if needle in source:
            print(f"paste spacing regression: punctuation-only spacing remains: {needle}", file=sys.stderr)
            failed = True

    if failed:
        return 1

    print("paste spacing static checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
