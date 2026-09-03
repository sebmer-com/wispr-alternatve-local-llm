#!/usr/bin/env python3
import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
BINARY = REPO_ROOT / "app" / ".build" / "debug" / "fluid-push-to-talk"
PNG_1X1 = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)


def resolve_api_key(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if value:
        return value
    dotenv = Path.home() / ".config" / "fluid-push-to-talk" / ".env"
    if not dotenv.exists():
        return ""
    for line in dotenv.read_text(encoding="utf-8").splitlines():
        key, separator, raw = line.partition("=")
        if separator and key.strip() == name:
            return raw.strip().strip("'\"")
    return ""


def main() -> int:
    parser = argparse.ArgumentParser(description="Optional live five-image provider smoke test")
    parser.add_argument("--provider", choices=["openai", "cerebras", "gemini"], required=True)
    args = parser.parse_args()
    key_names = {
        "openai": "OPENAI_API_KEY",
        "cerebras": "CEREBRAS_API_KEY",
        "gemini": "GEMINI_API_KEY",
    }
    key_name = key_names[args.provider]
    api_key = resolve_api_key(key_name)
    if not api_key:
        print(f"SKIP {args.provider} multi-image live test: {key_name} is unavailable")
        return 0

    config = json.loads((REPO_ROOT / "config" / "config.json").read_text(encoding="utf-8"))
    config["command_provider"] = args.provider
    config["prompt_config_file"] = str(REPO_ROOT / "config" / "promptConfig.json")
    with tempfile.TemporaryDirectory() as temp_dir:
        root = Path(temp_dir)
        config_path = root / "config.json"
        config_path.write_text(json.dumps(config), encoding="utf-8")
        dotenv_path = root / ".env"
        dotenv_path.write_text(f"{key_name}={api_key}\n", encoding="utf-8")
        dotenv_path.chmod(0o600)
        images = []
        for index in range(5):
            image = root / f"fixture-{index}.png"
            image.write_bytes(PNG_1X1)
            images.append(image)

        command = [
            str(BINARY),
            "--config", str(config_path),
            "--test-command-information", "Five numbered screenshots are attached in order.",
            "--test-command", "Reply with exactly OK.",
        ]
        for image in images:
            command.extend(["--test-command-image", str(image)])
        completed = subprocess.run(command, cwd=REPO_ROOT, text=True, capture_output=True, timeout=90)

    if completed.stdout:
        print(completed.stdout, end="")
    if completed.stderr:
        print(completed.stderr, end="", file=sys.stderr)
    if completed.returncode != 0:
        return completed.returncode
    if "[result]" not in completed.stdout:
        print(f"{args.provider} multi-image live test: missing result", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
