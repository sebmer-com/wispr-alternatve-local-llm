#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
BINARY = REPO_ROOT / "app" / ".build" / "debug" / "fluid-push-to-talk"
INFORMATION = "The required token is OK."
COMMAND = "Return exactly the required token and nothing else."
MAX_LATENCY_SECONDS = 45.0


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

def main() -> int:
    config = json.loads((REPO_ROOT / "config" / "config.json").read_text(encoding="utf-8"))
    config["command_provider"] = "openai"
    config["command_auth"] = "api_key"
    config["command_model"] = "gpt-6-luna"
    config["prompt_config_file"] = str(REPO_ROOT / "config" / "promptConfig.json")
    api_key = resolve_api_key()
    if not api_key:
        print("OpenAI command smoke regression: OPENAI_API_KEY is unavailable", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory() as temp_dir:
        config_path = Path(temp_dir) / "config.json"
        config_path.write_text(json.dumps(config), encoding="utf-8")
        dotenv_path = Path(temp_dir) / ".env"
        dotenv_path.write_text(f"OPENAI_API_KEY={api_key}\n", encoding="utf-8")
        dotenv_path.chmod(0o600)

        started = time.monotonic()
        completed = subprocess.run(
            [
                str(BINARY),
                "--config",
                str(config_path),
                "--test-command-information",
                INFORMATION,
                "--test-command",
                COMMAND,
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=MAX_LATENCY_SECONDS,
        )
        elapsed = time.monotonic() - started

    print(completed.stdout, end="")
    if completed.stderr:
        print(completed.stderr, end="", file=sys.stderr)
    if completed.returncode != 0:
        return completed.returncode

    if "sending command request to OpenAI gpt-6-luna" not in completed.stdout:
        print("OpenAI command smoke regression: command route did not use fixed Luna model", file=sys.stderr)
        return 1

    result_lines = [
        line.removeprefix("[result] ").strip()
        for line in completed.stdout.splitlines()
        if line.startswith("[result] ")
    ]
    if not result_lines:
        print("hosted command smoke regression: app did not print a [result] line", file=sys.stderr)
        return 1
    if result_lines[-1].strip().strip(".") != "OK":
        print(f"hosted command smoke regression: expected OK, got {result_lines[-1]!r}", file=sys.stderr)
        return 1

    print(f"OpenAI Responses command smoke completed in {elapsed:.2f}s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
