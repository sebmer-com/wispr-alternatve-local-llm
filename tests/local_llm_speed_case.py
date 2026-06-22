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

    with tempfile.TemporaryDirectory() as temp_dir:
        config_path = Path(temp_dir) / "config.json"
        config_path.write_text(json.dumps(config), encoding="utf-8")

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

    expected_route = f"sending command LLM request to OpenAI-compatible {config['local_llm']['model']}"
    if expected_route not in completed.stdout:
        print("OpenAI-compatible command smoke regression: command route did not use configured provider", file=sys.stderr)
        return 1

    result_lines = [
        line.removeprefix("[result] ").strip()
        for line in completed.stdout.splitlines()
        if line.startswith("[result] ")
    ]
    if not result_lines:
        print("OpenAI-compatible command smoke regression: app did not print a [result] line", file=sys.stderr)
        return 1
    if result_lines[-1].strip().strip(".") != "OK":
        print(f"OpenAI-compatible command smoke regression: expected OK, got {result_lines[-1]!r}", file=sys.stderr)
        return 1

    print(f"OpenAI-compatible command LLM smoke completed in {elapsed:.2f}s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
