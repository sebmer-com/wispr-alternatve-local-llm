#!/usr/bin/env python3
import json
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
BINARY = REPO_ROOT / "app" / ".build" / "debug" / "fluid-push-to-talk"


def run_setup(provider_choice: str, selected_key: str, mode_choice: str, existing_env: str) -> tuple[subprocess.CompletedProcess[str], dict, str]:
    with tempfile.TemporaryDirectory() as temp_dir:
        config_path = Path(temp_dir) / "config.json"
        dotenv_path = Path(temp_dir) / ".env"
        dotenv_path.write_text(existing_env, encoding="utf-8")
        # Language default, paste shortcut default, provider, hidden key,
        # Control + Option mode, optional dump path, save confirmation.
        dump_path_answer = "\n" if mode_choice == "1" else ""
        input_text = f"\n\n{provider_choice}\n{selected_key}\n{mode_choice}\n{dump_path_answer}y\n"
        completed = subprocess.run(
            [str(BINARY), "setup", "--config", str(config_path)],
            cwd=REPO_ROOT,
            input=input_text,
            text=True,
            capture_output=True,
            timeout=20,
        )
        config = json.loads(config_path.read_text(encoding="utf-8")) if config_path.exists() else {}
        dotenv = dotenv_path.read_text(encoding="utf-8")
        return completed, config, dotenv


def require(condition: bool, message: str) -> bool:
    if condition:
        return False
    print(f"command provider wizard regression: {message}", file=sys.stderr)
    return True


def main() -> int:
    failed = False
    openai_key = "sk-openai-new-test-value"
    openai, config, dotenv = run_setup(
        "1",
        openai_key,
        "1",
        "OPENAI_API_KEY=old-openai\nCEREBRAS_API_KEY=keep-cerebras\n",
    )
    failed |= require(openai.returncode == 0, "piped OpenAI onboarding must succeed")
    failed |= require(config.get("command_provider") == "openai", "OpenAI selection must write command_provider=openai")
    failed |= require(config.get("control_option_mode") == "dump", "Markdown selection must write control_option_mode=dump")
    failed |= require(config.get("dump", {}).get("enabled") is True, "Markdown selection must enable dump output")
    failed |= require(f"OPENAI_API_KEY={openai_key}" in dotenv, "OpenAI selection must update OPENAI_API_KEY")
    failed |= require("CEREBRAS_API_KEY=keep-cerebras" in dotenv, "OpenAI selection must preserve CEREBRAS_API_KEY")
    failed |= require(openai_key not in openai.stdout + openai.stderr, "hidden OpenAI key must not be echoed")

    cerebras_key = "csk-cerebras-new-test-value"
    cerebras, config, dotenv = run_setup(
        "2",
        cerebras_key,
        "2",
        "OPENAI_API_KEY=keep-openai\nCEREBRAS_API_KEY=old-cerebras\n",
    )
    failed |= require(cerebras.returncode == 0, "piped Cerebras onboarding must succeed")
    failed |= require(config.get("command_provider") == "cerebras", "Cerebras selection must write command_provider=cerebras")
    failed |= require(config.get("control_option_mode") == "hermes", "Hermes selection must write control_option_mode=hermes")
    failed |= require("enabled" not in config.get("hermes_agent", {}), "Hermes selection must not write legacy enabled flag")
    failed |= require(f"CEREBRAS_API_KEY={cerebras_key}" in dotenv, "Cerebras selection must update CEREBRAS_API_KEY")
    failed |= require("OPENAI_API_KEY=keep-openai" in dotenv, "Cerebras selection must preserve OPENAI_API_KEY")
    failed |= require(cerebras_key not in cerebras.stdout + cerebras.stderr, "hidden Cerebras key must not be echoed")

    gemini_key = "AIzaSy-gemini-new-test-value"
    gemini, config, dotenv = run_setup(
        "3",
        gemini_key,
        "1",
        "OPENAI_API_KEY=keep-openai\nCEREBRAS_API_KEY=keep-cerebras\nGEMINI_API_KEY=old-gemini\n",
    )
    failed |= require(gemini.returncode == 0, "piped Gemini onboarding must succeed")
    failed |= require(config.get("command_provider") == "gemini", "Gemini selection must write command_provider=gemini")
    failed |= require(config.get("control_option_mode") == "dump", "Markdown selection must write control_option_mode=dump")
    failed |= require(config.get("dump", {}).get("enabled") is True, "Markdown selection must enable dump output")
    failed |= require(f"GEMINI_API_KEY={gemini_key}" in dotenv, "Gemini selection must update GEMINI_API_KEY")
    failed |= require("OPENAI_API_KEY=keep-openai" in dotenv, "Gemini selection must preserve OPENAI_API_KEY")
    failed |= require("CEREBRAS_API_KEY=keep-cerebras" in dotenv, "Gemini selection must preserve CEREBRAS_API_KEY")
    failed |= require(gemini_key not in gemini.stdout + gemini.stderr, "hidden Gemini key must not be echoed")

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
