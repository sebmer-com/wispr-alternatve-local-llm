#!/usr/bin/env python3
import os
import subprocess
import sys
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "skills" / "tasks" / "scripts" / "add_task.py"


def run_task_tool(note: Path, information: str, command: str) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["FLUID_OBSIDIAN_DAILY_NOTE"] = str(note)
    env["FLUID_TASK_TODAY"] = "2026-05-09"
    env["FLUID_SKILL_INFORMATION"] = information
    env["FLUID_SKILL_COMMAND"] = command
    return subprocess.run(
        ["python3", str(SCRIPT)],
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
        env=env,
    )


def assert_case(completed: subprocess.CompletedProcess[str], note: Path, expected_line: str, label: str) -> bool:
    print(completed.stdout, end="")
    if completed.stderr:
        print(completed.stderr, end="", file=sys.stderr)
    if completed.returncode != 0:
        print(f"{label}: tool exited with {completed.returncode}", file=sys.stderr)
        return False
    content = note.read_text(encoding="utf-8")
    if expected_line not in content:
        print(f"{label}: expected task line missing: {expected_line!r}", file=sys.stderr)
        print(content, file=sys.stderr)
        return False
    if f"Task added: {expected_line}" not in completed.stdout:
        print(f"{label}: tool output did not include created task", file=sys.stderr)
        return False
    return True


def main() -> int:
    with tempfile.TemporaryDirectory() as temp_dir:
        note = Path(temp_dir) / "2026-05-09.md"

        first = run_task_tool(
            note,
            "Assignment EMBA",
            "Bitte als Task hinzufügen bis 2026-06-09 mit hoher Priorität.",
        )
        expected_first = "- [ ] #task Assignment EMBA 🔺 ➕ 2026-05-09 📅 2026-06-09"
        if not assert_case(first, note, expected_first, "explicit due date task regression"):
            return 1

        second = run_task_tool(
            note,
            "Review slides",
            "Task für morgen mit niedriger Priorität hinzufügen.",
        )
        expected_second = "- [ ] #task Review slides 🔽 ➕ 2026-05-09 📅 2026-05-10"
        if not assert_case(second, note, expected_second, "relative due date task regression"):
            return 1

    print("tasks skill checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
