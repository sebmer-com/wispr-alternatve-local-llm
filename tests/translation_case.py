#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
BINARY = REPO_ROOT / "app" / ".build" / "debug" / "fluid-push-to-talk"
SOURCE = "Ja, genau, einfach mal so reingehauen."
COMMAND = "Bitte auf Englisch übersetzen."
MAX_ATTEMPTS = 3


def run_once(config_path: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            str(BINARY),
            "--config",
            str(config_path),
            "--test-command-information",
            SOURCE,
            "--test-command",
            COMMAND,
        ],
        check=False,
        capture_output=True,
        text=True,
        timeout=45,
    )


def validate(completed: subprocess.CompletedProcess[str]) -> bool:
    if completed.returncode != 0:
        return False

    command_index = completed.stdout.find(COMMAND)
    information_index = completed.stdout.find(SOURCE)
    if command_index == -1 or information_index == -1 or command_index > information_index:
        print("translation regression: LLM request did not put command before information", file=sys.stderr)
        return False

    result_lines = [
        line.removeprefix("[result] ").strip()
        for line in completed.stdout.splitlines()
        if line.startswith("[result] ")
    ]
    if not result_lines:
        print("translation regression: app did not print a [result] line", file=sys.stderr)
        return False

    content = result_lines[-1]
    if content == SOURCE:
        print("translation regression: model repeated the German source", file=sys.stderr)
        return False
    if "yes" not in content.lower():
        print("translation regression: expected an English translation containing 'yes'", file=sys.stderr)
        return False
    return True


def main() -> int:
    config = json.loads((REPO_ROOT / "config" / "config.json").read_text(encoding="utf-8"))
    config["prompt_config_file"] = str(REPO_ROOT / "config" / "promptConfig.json")
    config.setdefault("local_llm", {})
    config["local_llm"]["enabled"] = True
    config["local_llm"]["command_generation_enabled"] = True
    config["local_llm"]["provider"] = "openai_compatible"
    config["local_llm"]["endpoint"] = ""
    config["local_llm"]["base_url"] = os.environ.get(
        "OPENAI_BASE_URL",
        config["local_llm"].get("base_url", "https://api.openai.com/v1"),
    )
    config["local_llm"]["model"] = os.environ.get(
        "OPENAI_MODEL",
        config["local_llm"].get("model", "gpt-5.4-mini"),
    )
    config["local_llm"]["api_key_env"] = "OPENAI_API_KEY"
    config.setdefault("debug", {})
    config["debug"]["log_llm_requests"] = True

    temp_dir = tempfile.TemporaryDirectory()
    config_path = Path(temp_dir.name) / "config.json"
    config_path.write_text(json.dumps(config), encoding="utf-8")

    last_completed = None
    for attempt in range(1, MAX_ATTEMPTS + 1):
        completed = run_once(config_path)
        last_completed = completed
        print(completed.stdout, end="")
        if completed.stderr:
            print(completed.stderr, end="", file=sys.stderr)
        if validate(completed):
            return 0
        if attempt < MAX_ATTEMPTS:
            print(f"translation regression: retrying live OpenAI-compatible command ({attempt + 1}/{MAX_ATTEMPTS})")
    if last_completed and last_completed.returncode != 0:
        return last_completed.returncode
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
