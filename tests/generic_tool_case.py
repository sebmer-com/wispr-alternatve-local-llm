#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
BINARY = REPO_ROOT / "app" / ".build" / "debug" / "fluid-push-to-talk"
CONFIG = REPO_ROOT / "config" / "config.json"


def write_test_greet_skill(skills_dir: Path) -> None:
    skill_dir = skills_dir / "test-greet"
    scripts_dir = skill_dir / "scripts"
    scripts_dir.mkdir(parents=True)
    (skill_dir / "SKILL.md").write_text(
        """---
name: test-greet
description: Use when asked to greet someone or greet out loud.
tool: scripts/greet.py
tool_fallback: true
tool_timeout_seconds: 5
---

Return a deterministic greeting for regression tests.
""",
        encoding="utf-8",
    )
    (scripts_dir / "greet.py").write_text(
        """#!/usr/bin/env python3
import os

name = os.environ.get("FLUID_SKILL_INFORMATION", "").strip()
print(f"Spoken: Hello {name}" if name else "Spoken: Hello")
""",
        encoding="utf-8",
    )


def run_case(config_path: Path, information: str, command: str) -> str:
    env = os.environ.copy()
    env["FLUID_SKILL_DRY_RUN"] = "1"
    completed = subprocess.run(
        [
            str(BINARY),
            "--config",
            str(config_path),
            "--test-command-information",
            information,
            "--test-command",
            command,
        ],
        check=False,
        capture_output=True,
        env=env,
        text=True,
        timeout=20,
    )
    if completed.returncode != 0:
        print(completed.stdout, end="")
        print(completed.stderr, end="", file=sys.stderr)
        raise SystemExit(completed.returncode)

    print(completed.stdout, end="")
    result_index = completed.stdout.find("[result] ")
    if result_index == -1:
        print("generic tool regression: app did not print a [result] line", file=sys.stderr)
        raise SystemExit(1)
    return completed.stdout[result_index + len("[result] "):].strip()


def main() -> int:
    with tempfile.TemporaryDirectory() as temp_dir:
        skills_dir = Path(temp_dir) / "skills"
        write_test_greet_skill(skills_dir)

        config = json.loads(CONFIG.read_text())
        config["local_llm"]["enabled"] = False
        config["skills"]["directory"] = str(skills_dir)
        config_path = Path(temp_dir) / "config.json"
        config_path.write_text(json.dumps(config), encoding="utf-8")

        named_greeting = run_case(
            config_path,
            "Dominik",
            "greet out loud",
        )
        if named_greeting != "Spoken: Hello Dominik":
            print(f"generic tool regression: unexpected named greet output: {named_greeting}", file=sys.stderr)
            return 1

        generic_greeting = run_case(
            config_path,
            "",
            "greet out loud",
        )
        if generic_greeting != "Spoken: Hello":
            print(f"generic tool regression: unexpected generic greet output: {generic_greeting}", file=sys.stderr)
            return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
