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
    errors = []
    if config.get("asr", {}).get("language") != "system":
        errors.append("asr.language must default to system")
    if "local_llm" in config:
        errors.append("legacy local_llm configuration must be removed")
    if "skills" in config:
        errors.append("legacy skills configuration must be removed")
    if config.get("command_provider") != "openai":
        errors.append("command_provider must default to openai")
    if config.get("control_option_mode") != "dump":
        errors.append("control_option_mode must default to dump")
    if "enabled" in config.get("hermes_agent", {}):
        errors.append("legacy hermes_agent.enabled must not be written")
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
    if llm_output.get("dump") != "dump":
        errors.append("Markdown Control + Option mode must default to dump output")
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
        "--test-command-image",
        "--test-hermes-instruction",
        "Control + Option is selected during setup",
    ]
    missing = [item for item in expected if item not in completed.stdout]
    if completed.returncode != 0 or missing:
        if missing:
            print(f"CLI help regression: missing {missing}", file=sys.stderr)
        print(color("FAIL CLI help", "31"), file=sys.stderr)
        return False
    print(color("PASS CLI help", "32"))
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description="Run LocalPTT automated regression checks.")
    parser.add_argument(
        "--skip-llm",
        action="store_true",
        help="Skip the live command LLM regressions.",
    )
    parser.add_argument(
        "--live-multi-image",
        action="store_true",
        help="Run optional five-image live checks for configured provider credentials.",
    )
    args = parser.parse_args()

    checks = [
        run("swift build", ["swift", "build"], cwd=APP_DIR),
        run("swift tests", ["swift", "test"], cwd=APP_DIR),
        run("config JSON", ["python3", "-m", "json.tool", "config/config.json"]),
        run("prompt JSON", ["python3", "-m", "json.tool", "config/promptConfig.json"]),
        run("text replacements JSON", ["python3", "-m", "json.tool", "config/textReplacements.json"]),
        validate_config(),
        validate_help(),
        run("audio recorder static regression", ["python3", "tests/audio_recorder_static_case.py"]),
        run("hotkey command-mode static regression", ["python3", "tests/hotkey_command_mode_static_case.py"]),
        run("command screenshot P-key regression", ["python3", "tests/command_screenshot_hotkey_static_case.py"]),
        run("Hermes shortcut static regression", ["python3", "tests/hermes_shortcut_static_case.py"]),
        run("paste spacing static regression", ["python3", "tests/paste_spacing_static_case.py"]),
        run("terminal launch static regression", ["python3", "tests/terminal_launch_static_case.py"]),
        run("installer static regression", ["python3", "tests/installer_static_case.py"]),
        run("markdown dump static regression", ["python3", "tests/markdown_dump_static_case.py"]),
        run("continuous dump static regression", ["python3", "tests/continuous_dump_static_case.py"]),
        run("Bluetooth keyboard static regression", ["python3", "tests/bluetooth_keyboard_static_case.py"]),
        run("Bluetooth keyboard protocol regression", ["python3", "tests/bluetooth_keyboard_protocol_case.py"]),
        run("OpenAI Responses static regression", ["python3", "tests/openai_responses_static_case.py"]),
        run("command provider static regression", ["python3", "tests/command_provider_static_case.py"]),
        run("command diagnostics static regression", ["python3", "tests/command_diagnostics_static_case.py"]),
        run("config wizard regression", ["python3", "tests/config_wizard_case.py"]),
        run("command provider piped onboarding regression", ["python3", "tests/command_provider_wizard_case.py"]),
        run("text replacement static regression", ["python3", "tests/text_replacement_static_case.py"]),
    ]
    if not args.skip_llm:
        checks.append(run("OpenAI Responses command smoke regression", ["python3", "tests/openai_responses_live_case.py"], timeout=60))
        checks.append(run("OpenAI Responses command translation regression", ["python3", "tests/translation_case.py"], timeout=150))
    else:
        print(color("SKIP OpenAI Responses command smoke regression", "33"))
        print(color("SKIP OpenAI Responses command translation regression", "33"))
    if args.live_multi_image:
        checks.append(run("OpenAI five-image live regression", ["python3", "tests/provider_multi_image_live_case.py", "--provider", "openai"], timeout=100))
        checks.append(run("Cerebras five-image live regression", ["python3", "tests/provider_multi_image_live_case.py", "--provider", "cerebras"], timeout=100))
        checks.append(run("Gemini five-image live regression", ["python3", "tests/provider_multi_image_live_case.py", "--provider", "gemini"], timeout=100))
    else:
        print(color("SKIP optional provider five-image live regressions", "33"))

    return 0 if all(checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
