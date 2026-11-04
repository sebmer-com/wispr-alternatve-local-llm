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


def resolve_api_key() -> str:
    value = os.environ.get("OPENAI_API_KEY", "").strip()
    if value:
        return value
    dotenv = Path.home() / ".config" / "fluid-push-to-talk" / ".env"
    if not dotenv.exists():
        return ""
    for line in dotenv.read_text(encoding="utf-8").splitlines():
        key, separator, raw = line.partition("=")
        if separator and key.strip() == "OPENAI_API_KEY":
            return raw.strip().strip("'\"")
    return ""

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
    config["command_provider"] = "openai"
    config["command_auth"] = "api_key"
    config["command_model"] = "gpt-6-luna"
    config["prompt_config_file"] = str(REPO_ROOT / "config" / "promptConfig.json")
    api_key = resolve_api_key()
    if not api_key:
        print("translation regression: OPENAI_API_KEY is unavailable", file=sys.stderr)
        return 2

    temp_dir = tempfile.TemporaryDirectory()
    config_path = Path(temp_dir.name) / "config.json"
    config_path.write_text(json.dumps(config), encoding="utf-8")
    dotenv_path = Path(temp_dir.name) / ".env"
    dotenv_path.write_text(f"OPENAI_API_KEY={api_key}\n", encoding="utf-8")
    dotenv_path.chmod(0o600)

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
            print(f"translation regression: retrying live OpenAI Responses command ({attempt + 1}/{MAX_ATTEMPTS})")
    if last_completed and last_completed.returncode != 0:
        return last_completed.returncode
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
