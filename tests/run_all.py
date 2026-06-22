#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
APP_DIR = REPO_ROOT / "app"
BINARY = APP_DIR / ".build" / "debug" / "fluid-push-to-talk"
REQUIRED_COMMAND_LLM_MODEL = "gpt-5.4-mini"
REQUIRED_COMMAND_LLM_PROVIDER = "openai_compatible"
REQUIRED_COMMAND_LLM_BASE_URL = "https://api.openai.com/v1"


def color(text: str, code: str) -> str:
    if os.environ.get("NO_COLOR") or not sys.stdout.isatty():
        return text
    return f"\033[{code}m{text}\033[0m"


def run(name: str, command: list[str], cwd: Path = REPO_ROOT, timeout: int = 120) -> bool:
    print(color(f"==> {name}", "36"))
    completed = subprocess.run(
        command,
        cwd=cwd,
        text=True,
        capture_output=True,
        timeout=timeout,
    )
    if completed.stdout:
        print(completed.stdout, end="")
    if completed.stderr:
        print(completed.stderr, end="", file=sys.stderr)
    if completed.returncode == 0:
        print(color(f"PASS {name}", "32"))
        return True
    print(color(f"FAIL {name} ({completed.returncode})", "31"), file=sys.stderr)
    return False


def validate_config() -> bool:
    print(color("==> config expectations", "36"))
    config = json.loads((REPO_ROOT / "config" / "config.json").read_text(encoding="utf-8"))
    local_llm = config["local_llm"]
    errors = []
    if local_llm.get("command_generation_enabled") is not True:
        errors.append("local_llm.command_generation_enabled must default to true")
    if local_llm.get("provider") != REQUIRED_COMMAND_LLM_PROVIDER:
        errors.append(f"local_llm.provider must be {REQUIRED_COMMAND_LLM_PROVIDER}")
    if local_llm["model"] != REQUIRED_COMMAND_LLM_MODEL:
        errors.append(f"local_llm.model must be {REQUIRED_COMMAND_LLM_MODEL}")
    if local_llm.get("base_url") != REQUIRED_COMMAND_LLM_BASE_URL:
        errors.append("local_llm.base_url must use the configured OpenAI-compatible base URL")
    if local_llm.get("api_key_env") != "OPENAI_API_KEY":
        errors.append("local_llm.api_key_env must default to OPENAI_API_KEY")
    if "api_key" in local_llm:
        errors.append("local_llm.api_key must not be stored in JSON; use .env")
    if local_llm.get("dotenv_file") != ".env":
        errors.append("local_llm.dotenv_file must default to .env")
    if local_llm["temperature"] != 0:
        errors.append("local_llm.temperature must be 0 for deterministic fast command generation")
    if local_llm["max_tokens"] > 128:
        errors.append("local_llm.max_tokens should stay small for latency")
    if local_llm.get("request_timeout_seconds") != 15:
        errors.append("local_llm.request_timeout_seconds must allow normal hosted API variance without old single-request stalls")
    if local_llm.get("max_retries") != 1:
        errors.append("local_llm.max_retries must retry one transient hosted API timeout without flooding the rate limit")
    if local_llm.get("cache_size") != 4096:
        errors.append("local_llm.cache_size must stay positive for MLX fallback compatibility")
    if local_llm.get("memory_size") != 4096:
        errors.append("local_llm.memory_size must stay positive for MLX fallback compatibility")
    if config.get("text_replacements_file") != "textReplacements.json":
        errors.append("text_replacements_file must default to textReplacements.json")
    if "/Users/dominik/" in json.dumps(config) or "/Users/sebastianmertens" in json.dumps(config):
        errors.append("checked-in config must not contain machine-specific user paths")
    audio_input = config.get("audio_input", {})
    if audio_input.get("device_uid") != "" or audio_input.get("device_name") != "":
        errors.append("audio_input must default to the macOS default input device unless configured")
    llm_output = config.get("llm_output", {})
    allowed_output_methods = {"clipboard", "dump", "bluetooth-keyboard"}
    if set(llm_output) != {"paste", "dump", "bluetooth"} or not set(llm_output.values()) <= allowed_output_methods:
        errors.append("llm_output must configure paste, dump, and bluetooth with supported output methods")
    if llm_output.get("paste") != "clipboard":
        errors.append("Command + Option must remain configured for local clipboard paste")
    if llm_output.get("bluetooth") != "clipboard":
        errors.append("Bluetooth output must default to clipboard while the Bluetooth hotkey is disabled")
    bluetooth_hotkey = config.get("hotkeys", {}).get("bluetooth", {})
    if bluetooth_hotkey.get("enabled") is not False:
        errors.append("Bluetooth hotkey must default to disabled with enabled=false")
    if bluetooth_hotkey.get("keys") != []:
        errors.append("Bluetooth hotkey must default to disabled")
    if config.get("bluetooth_keyboard", {}).get("chunk_size") != 32:
        errors.append("bluetooth_keyboard.chunk_size must default to 32")
    if errors:
        for error in errors:
            print(f"config regression: {error}", file=sys.stderr)
        print(color("FAIL config expectations", "31"), file=sys.stderr)
        return False
    print(color("PASS config expectations", "32"))
    return True


def validate_help() -> bool:
    if not BINARY.exists():
        print(f"missing binary at {BINARY}; build must run first", file=sys.stderr)
        return False
    print(color("==> CLI help", "36"))
    completed = subprocess.run(
        [str(BINARY), "--help"],
        cwd=REPO_ROOT,
        text=True,
        capture_output=True,
        timeout=10,
    )
    if completed.stdout:
        print(completed.stdout, end="")
    if completed.stderr:
        print(completed.stderr, end="", file=sys.stderr)

    expected = [
        "FluidAudio Push To Talk 0.2.3",
        "--config PATH",
        "--model-version v3|v2",
        "--test-command-information",
        "--test-command",
    ]
    missing = [item for item in expected if item not in completed.stdout]
    if completed.returncode != 0 or missing:
        if missing:
            print(f"CLI help regression: missing {missing}", file=sys.stderr)
        print(color("FAIL CLI help", "31"), file=sys.stderr)
        return False
    print(color("PASS CLI help", "32"))
    return True


def validate_skill_frontmatter() -> bool:
    print(color("==> skill frontmatter", "36"))
    failed = False
    for skill in sorted((REPO_ROOT / "skills").glob("*/SKILL.md")):
        lines = skill.read_text(encoding="utf-8").splitlines()
        if len(lines) < 4 or lines[0] != "---":
            print(f"skill frontmatter regression: {skill} must start with YAML frontmatter", file=sys.stderr)
            failed = True
            continue
        header = "\n".join(lines[:8])
        if "name:" not in header or "description:" not in header:
            print(f"skill frontmatter regression: {skill} needs name and description", file=sys.stderr)
            failed = True
    if failed:
        print(color("FAIL skill frontmatter", "31"), file=sys.stderr)
        return False
    print(color("PASS skill frontmatter", "32"))
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description="Run LocalPTT automated regression checks.")
    parser.add_argument(
        "--skip-llm",
        action="store_true",
        help="Skip the live command LLM regressions.",
    )
    args = parser.parse_args()

    checks = [
        run("swift build", ["swift", "build"], cwd=APP_DIR),
        run("config JSON", ["python3", "-m", "json.tool", "config/config.json"]),
        run("prompt JSON", ["python3", "-m", "json.tool", "config/promptConfig.json"]),
        run("text replacements JSON", ["python3", "-m", "json.tool", "config/textReplacements.json"]),
        validate_config(),
        validate_help(),
        validate_skill_frontmatter(),
        run("audio recorder static regression", ["python3", "tests/audio_recorder_static_case.py"]),
        run("hotkey command-mode static regression", ["python3", "tests/hotkey_command_mode_static_case.py"]),
        run("Hermes shortcut static regression", ["python3", "tests/hermes_shortcut_static_case.py"]),
        run("paste spacing static regression", ["python3", "tests/paste_spacing_static_case.py"]),
        run("terminal launch static regression", ["python3", "tests/terminal_launch_static_case.py"]),
        run("installer static regression", ["python3", "tests/installer_static_case.py"]),
        run("markdown dump static regression", ["python3", "tests/markdown_dump_static_case.py"]),
        run("continuous dump static regression", ["python3", "tests/continuous_dump_static_case.py"]),
        run("Bluetooth keyboard static regression", ["python3", "tests/bluetooth_keyboard_static_case.py"]),
        run("Bluetooth keyboard protocol regression", ["python3", "tests/bluetooth_keyboard_protocol_case.py"]),
        run("command LLM provider static regression", ["python3", "tests/local_llm_model_static_case.py"]),
        run("config wizard regression", ["python3", "tests/config_wizard_case.py"]),
        run("text replacement static regression", ["python3", "tests/text_replacement_static_case.py"]),
        run("tasks skill regression", ["python3", "tests/tasks_skill_case.py"]),
        run("command LLM toggle regression", ["python3", "tests/command_llm_toggle_case.py"]),
        run("generic skill tool regression", ["python3", "tests/generic_tool_case.py"]),
    ]
    if not args.skip_llm:
        checks.append(run("OpenAI-compatible command LLM smoke regression", ["python3", "tests/local_llm_speed_case.py"], timeout=60))
        checks.append(run("OpenAI-compatible command translation regression", ["python3", "tests/translation_case.py"], timeout=150))
    else:
        print(color("SKIP OpenAI-compatible command LLM smoke regression", "33"))
        print(color("SKIP OpenAI-compatible command translation regression", "33"))

    return 0 if all(checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
