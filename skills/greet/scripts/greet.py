#!/usr/bin/env python3
import os
import re
import subprocess
import sys


def name_from_information(information: str) -> str | None:
    text = information.strip()
    if not text:
        return None

    patterns = [
        r"\bmy name is\s+([A-Za-zÀ-ÿ][A-Za-zÀ-ÿ .'-]{0,80})",
        r"\bi am\s+([A-Za-zÀ-ÿ][A-Za-zÀ-ÿ .'-]{0,80})",
        r"\bi'm\s+([A-Za-zÀ-ÿ][A-Za-zÀ-ÿ .'-]{0,80})",
        r"\bmein name ist\s+([A-Za-zÀ-ÿ][A-Za-zÀ-ÿ .'-]{0,80})",
        r"\bich bin\s+([A-Za-zÀ-ÿ][A-Za-zÀ-ÿ .'-]{0,80})",
    ]
    for pattern in patterns:
        match = re.search(pattern, text, flags=re.IGNORECASE)
        if match:
            return clean_name(match.group(1))

    if len(text.split()) <= 4:
        return clean_name(text)

    return None


def clean_name(value: str) -> str:
    return re.sub(r"\s+", " ", value).strip(" .,!?:;\"'")


def greeting_text() -> str:
    name = name_from_information(os.environ.get("FLUID_SKILL_INFORMATION", ""))
    return f"Hello {name}" if name else "Hello"


def main() -> int:
    greeting = greeting_text()
    if os.environ.get("FLUID_SKILL_ALLOW_SPEECH") == "1":
        completed = subprocess.run(
            ["/usr/bin/say", greeting],
            check=False,
            capture_output=True,
            text=True,
            timeout=4,
        )
        if completed.returncode != 0:
            if completed.stderr:
                print(completed.stderr.strip(), file=sys.stderr)
            return completed.returncode

    print(f"Greeting: {greeting}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
