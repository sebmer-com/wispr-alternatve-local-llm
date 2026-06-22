#!/usr/bin/env python3
import json
import subprocess
import sys
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
BINARY = REPO_ROOT / "app" / ".build" / "debug" / "fluid-push-to-talk"
CONFIG = REPO_ROOT / "config" / "config.json"
INFORMATION = "Bitte genau diesen Text verwenden."
COMMAND = "Formuliere das eleganter."


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


def run_command(config_path: Path, information: str, command: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
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
        text=True,
        timeout=20,
    )


def assert_disabled_without_llm_request(
    completed: subprocess.CompletedProcess[str],
    expected_result: str,
    label: str,
) -> bool:
    print(completed.stdout, end="")
    if completed.stderr:
        print(completed.stderr, end="", file=sys.stderr)
    if completed.returncode != 0:
        return False

    if "command LLM disabled; using fallback result" not in completed.stdout:
        print(f"{label}: disabled command LLM was not logged", file=sys.stderr)
        return False
    if "sending command LLM request" in completed.stdout:
        print(f"{label}: command LLM request was sent despite disabled toggle", file=sys.stderr)
        return False
    if f"[result] {expected_result}" not in completed.stdout:
        print(f"{label}: fallback result was not {expected_result!r}", file=sys.stderr)
        return False
    return True


def main() -> int:
    with tempfile.TemporaryDirectory() as temp_dir:
        skills_dir = Path(temp_dir) / "skills"
        write_test_greet_skill(skills_dir)

        config = json.loads(CONFIG.read_text(encoding="utf-8"))
        config["prompt_config_file"] = str(REPO_ROOT / "config" / "promptConfig.json")
        config["local_llm"]["enabled"] = True
        config["local_llm"]["command_generation_enabled"] = False
        config["skills"]["directory"] = str(skills_dir)
        config_path = Path(temp_dir) / "config.json"
        config_path.write_text(json.dumps(config), encoding="utf-8")

        transcript_fallback = run_command(config_path, INFORMATION, COMMAND)
        if not assert_disabled_without_llm_request(
            transcript_fallback,
            INFORMATION,
            "command LLM transcript fallback regression",
        ):
            return 1

        skill_tool_fallback = run_command(config_path, "Dominik", "greet out loud")
        if not assert_disabled_without_llm_request(
            skill_tool_fallback,
            "Spoken: Hello Dominik",
            "command LLM skill-tool fallback regression",
        ):
            return 1

        reversed_question_fallback = run_command(
            config_path,
            "Beantworte bitte die folgende Frage.",
            "Was sind Katzen?",
        )
        if not assert_disabled_without_llm_request(
            reversed_question_fallback,
            "Was sind Katzen?",
            "command LLM reversed question fallback regression",
        ):
            return 1

    print("command LLM toggle checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
