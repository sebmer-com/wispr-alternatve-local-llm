#!/usr/bin/env python3
import os
import re
import sys
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Optional


PRIORITIES = [
    (("highest", "urgent", "dringend", "sehr wichtig", "höchste", "hoechste", "hoch", "wichtig"), "🔺"),
    (("high", "hohe priorität", "hohe prioritaet"), "⏫"),
    (("medium", "mittel", "mittlere"), "🔼"),
    (("low", "niedrig", "gering"), "🔽"),
    (("lowest", "sehr niedrig"), "⏬"),
]


def today() -> date:
    override = os.environ.get("FLUID_TASK_TODAY", "").strip()
    if override:
        return datetime.strptime(override, "%Y-%m-%d").date()
    return date.today()


def looks_like_task_instruction(text: str) -> bool:
    normalized = normalize(text)
    phrases = [
        "task",
        "todo",
        "to do",
        "aufgabe",
        "erinnerung",
        "hinzufugen",
        "hinzufügen",
        "anlegen",
        "erstellen",
        "speichern",
    ]
    return any(phrase in normalized for phrase in phrases)


def normalize(text: str) -> str:
    return text.strip().lower()


def extract_due(text: str, base_date: date) -> Optional[date]:
    normalized = normalize(text)

    iso_match = re.search(r"\b(20\d{2}-\d{2}-\d{2})\b", text)
    if iso_match:
        return datetime.strptime(iso_match.group(1), "%Y-%m-%d").date()

    german_match = re.search(r"\b(\d{1,2})\.(\d{1,2})\.(20\d{2})\b", text)
    if german_match:
        day, month, year = map(int, german_match.groups())
        return date(year, month, day)

    if "übermorgen" in normalized or "uebermorgen" in normalized:
        return base_date + timedelta(days=2)
    if "morgen" in normalized or "tomorrow" in normalized:
        return base_date + timedelta(days=1)
    if "heute" in normalized or "today" in normalized:
        return base_date

    days_match = re.search(r"\bin\s+(\d{1,3})\s+(?:tag|tagen|days?)\b", normalized)
    if days_match:
        return base_date + timedelta(days=int(days_match.group(1)))

    return None


def extract_priority(text: str) -> str:
    normalized = normalize(text)
    for keywords, emoji in PRIORITIES:
        if any(keyword in normalized for keyword in keywords):
            return emoji
    return "🔺"


def pick_description(information: str, command: str) -> str:
    candidates = [information.strip(), command.strip()]
    non_instruction = [candidate for candidate in candidates if candidate and not looks_like_task_instruction(candidate)]
    source = non_instruction[0] if non_instruction else " ".join(candidate for candidate in candidates if candidate)
    return clean_description(source)


def clean_description(text: str) -> str:
    cleaned = text.strip()
    replacements = [
        r"\b(?:bitte\s+)?(?:füge|fuege|erstelle|lege|speichere|append|add|create|save)\b.*?\b(?:task|todo|aufgabe|erinnerung)\b",
        r"\b(?:als|as)\s+(?:task|todo|aufgabe)\b",
        r"\b(?:bis|due|fällig|faellig|am|on)\s+20\d{2}-\d{2}-\d{2}\b",
        r"\b\d{1,2}\.\d{1,2}\.20\d{2}\b",
        r"\b(?:bis\s+)?(?:morgen|übermorgen|uebermorgen|heute|tomorrow|today)\b",
        r"\b(?:mit\s+)?(?:hoher|höchster|hoechster|niedriger|mittlerer)?\s*priorität\b",
        r"\b(?:dringend|urgent|wichtig)\b",
        r"#task",
    ]
    for pattern in replacements:
        cleaned = re.sub(pattern, " ", cleaned, flags=re.IGNORECASE)
    cleaned = re.sub(r"\s+", " ", cleaned)
    return cleaned.strip(" -.,;:!?")


def task_line(description: str, created: date, due: Optional[date], priority: str) -> str:
    parts = [f"- [ ] #task {description}", priority, f"➕ {created:%Y-%m-%d}"]
    if due:
        parts.append(f"📅 {due:%Y-%m-%d}")
    return " ".join(parts)


def append_task(path: Path, line: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    prefix = ""
    if path.exists() and path.stat().st_size > 0:
        prefix = "\n"
    with path.open("a", encoding="utf-8") as handle:
        handle.write(f"{prefix}{line}\n")


def main() -> int:
    note_path = os.environ.get("FLUID_OBSIDIAN_DAILY_NOTE", "").strip()
    if not note_path:
        print("FLUID_OBSIDIAN_DAILY_NOTE is not set", file=sys.stderr)
        return 1

    information = os.environ.get("FLUID_SKILL_INFORMATION", "")
    command = os.environ.get("FLUID_SKILL_COMMAND", "")
    created = today()
    combined = f"{information}\n{command}"
    description = pick_description(information, command)
    if not description:
        print("No task description found", file=sys.stderr)
        return 1

    line = task_line(
        description=description,
        created=created,
        due=extract_due(combined, created),
        priority=extract_priority(combined),
    )
    append_task(Path(note_path).expanduser(), line)
    print(f"Task added: {line}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
