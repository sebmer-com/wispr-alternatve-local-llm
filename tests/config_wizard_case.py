#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Optional


REPO_ROOT = Path(__file__).resolve().parents[1]
BINARY = REPO_ROOT / "app" / ".build" / "debug" / "fluid-push-to-talk"


def run_command(args: list[str], *, input_text: str = "", env: Optional[dict[str, str]] = None) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        [str(BINARY), *args],
        cwd=REPO_ROOT,
        input=input_text,
        text=True,
        capture_output=True,
        timeout=20,
        env=env,
    )
    print(completed.stdout, end="")
    if completed.stderr:
        print(completed.stderr, end="", file=sys.stderr)
    return completed


def assert_true(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> int:
    help_output = run_command(["--help"])
    assert_true(help_output.returncode == 0, "help command failed")
    for expected in ["setup [--config PATH]", "config [show|doctor|reset]", "config doctor", "config reset --yes"]:
        assert_true(expected in help_output.stdout, f"help output missing {expected!r}")

    checked_in_config = json.loads((REPO_ROOT / "config" / "config.json").read_text(encoding="utf-8"))
    assert_true("api_key" not in checked_in_config.get("local_llm", {}), "checked-in config must not store api_key")
    wizard_source = (REPO_ROOT / "app" / "Sources" / "CLI" / "ConfigWizard.swift").read_text(encoding="utf-8")
    assert_true("let pollInterval: useconds_t = 50_000" in wizard_source, "shortcut capture must poll at 50ms")
    assert_true("let stableDuration: TimeInterval = 0.35" in wizard_source, "shortcut capture must wait for a stable shortcut")
    assert_true("Hermes Agent aktivieren?" in wizard_source, "setup wizard must expose Hermes Agent onboarding")
    assert_true("hermesTriggerSummary" in wizard_source, "setup wizard must explain the Hermes trigger")
    options_source = (REPO_ROOT / "app" / "Sources" / "CLI" / "Options.swift").read_text(encoding="utf-8")
    assert_true(
        "options.testCommandInformation != nil || options.testCommand != nil" in options_source,
        "missing API keys must not abort normal dictation startup",
    )
    readiness_source = (REPO_ROOT / "app" / "Sources" / "LocalLLM" / "LocalLLMReadinessMonitor.swift").read_text(encoding="utf-8")
    assert_true(
        "dictation stays available" in readiness_source,
        "readiness monitor must warn without blocking dictation when hosted API keys are missing",
    )

    with tempfile.TemporaryDirectory() as temp_dir:
        config_path = Path(temp_dir) / "config.json"
        setup = run_command(["setup", "--config", str(config_path)], input_text="\n\n\n\n\n\n")
        assert_true(setup.returncode == 0, "setup wizard failed with empty token")
        assert_true((Path(temp_dir) / ".env").exists(), "setup must create .env even when token is empty")
        quickstart_config = json.loads(config_path.read_text(encoding="utf-8"))
        assert_true(
            quickstart_config["hermes_agent"]["enabled"] is True,
            "quickstart setup must keep Hermes Agent explicitly enabled by default",
        )
        assert_true(
            quickstart_config["hotkeys"]["bluetooth"]["keys"] == [],
            "quickstart setup must leave Bluetooth hotkey disabled",
        )
        assert_true(
            quickstart_config["hotkeys"]["bluetooth"]["enabled"] is False,
            "quickstart setup must write Bluetooth hotkey enabled=false",
        )
        assert_true(
            quickstart_config["llm_output"]["bluetooth"] == "clipboard",
            "quickstart setup must leave Bluetooth output local",
        )

    with tempfile.TemporaryDirectory() as temp_dir:
        config_path = Path(temp_dir) / "config.json"
        dotenv_path = Path(temp_dir) / ".env"
        config_path.write_text('{"local_llm":{"api_key":"bad","provider":"mlx"}}', encoding="utf-8")
        dotenv_path.write_text("OPENAI_API_KEY=remove-me\nOTHER_SECRET=remove-me-too\n", encoding="utf-8")

        reset = run_command(["config", "reset", "--yes", "--config", str(config_path)])
        assert_true(reset.returncode == 0, "config reset failed")
        reset_config = json.loads(config_path.read_text(encoding="utf-8"))
        assert_true("api_key" not in reset_config.get("local_llm", {}), "config reset must not write api_key")
        assert_true(reset_config["local_llm"]["api_key_env"] == "OPENAI_API_KEY", "config reset must use OPENAI_API_KEY")
        assert_true(reset_config["hermes_agent"]["enabled"] is True, "config reset must write the Hermes default explicitly")
        assert_true(reset_config["hermes_agent"]["workdir"] == "~", "config reset must keep Hermes workdir local-user neutral")
        assert_true(reset_config["hotkeys"]["bluetooth"]["enabled"] is False, "config reset must disable Bluetooth")
        assert_true(reset_config["hotkeys"]["bluetooth"]["keys"] == [], "config reset must clear Bluetooth keys")
        assert_true(reset_config["llm_output"]["bluetooth"] == "clipboard", "config reset must keep Bluetooth output inactive")
        assert_true("/Users/dominik/" not in json.dumps(reset_config), "config reset must remove old absolute user paths")
        assert_true(dotenv_path.exists(), "config reset must create an empty .env")
        assert_true("OPENAI_API_KEY" not in dotenv_path.read_text(encoding="utf-8"), "config reset must remove local secrets")

    with tempfile.TemporaryDirectory() as temp_dir:
        config_path = Path(temp_dir) / "config.json"
        dotenv_path = Path(temp_dir) / ".env"
        dotenv_path.write_text("OTHER_SECRET=keep-me\nOPENAI_API_KEY=old\n", encoding="utf-8")

        setup_input = "\nsk-new-secret-1234\n\n\n\n\n"
        setup = run_command(["setup", "--config", str(config_path)], input_text=setup_input)
        assert_true(setup.returncode == 0, "setup wizard failed")
        config = json.loads(config_path.read_text(encoding="utf-8"))
        local_llm = config["local_llm"]
        assert_true(local_llm["provider"] == "openai_compatible", "default setup must use OpenAI-compatible provider")
        assert_true(local_llm["base_url"] == "https://api.openai.com/v1", "default setup must use OpenAI base URL")
        assert_true(local_llm["api_key_env"] == "OPENAI_API_KEY", "default setup must use generic OPENAI_API_KEY")
        assert_true("api_key" not in local_llm, "setup config must not write api_key")
        assert_true(local_llm["dotenv_file"] == ".env", "setup must keep local .env reference")
        assert_true(config["skills"]["directory"] == str(REPO_ROOT / "skills"), "setup must point skills at current repo")
        assert_true(config["hermes_agent"]["enabled"] is True, "default setup must keep Hermes Agent enabled")
        assert_true(config["hermes_agent"]["workdir"] == "~", "default setup must keep Hermes workdir user-neutral")
        assert_true("/Users/dominik/" not in config["dump"]["markdown_file"], "setup must not keep old Dominik daily-note path")
        assert_true(config["hotkeys"]["bluetooth"]["keys"] == [], "default setup must not enable Bluetooth hotkey")
        assert_true(config["hotkeys"]["bluetooth"]["enabled"] is False, "default setup must write Bluetooth enabled=false")
        assert_true(config["llm_output"]["bluetooth"] == "clipboard", "default setup must not enable Bluetooth output")
        dotenv = dotenv_path.read_text(encoding="utf-8")
        assert_true("OTHER_SECRET=keep-me" in dotenv, ".env update must preserve unrelated keys")
        assert_true("OPENAI_API_KEY=sk-new-secret-1234" in dotenv, ".env update must replace OpenAI key")

        show = run_command(["config", "show", "--config", str(config_path)])
        assert_true(show.returncode == 0, "config show failed")
        assert_true("sk-new-secret-1234" not in show.stdout, "config show must not print raw API key")
        assert_true("sk-n...1234" in show.stdout, "config show must print masked API key")
        assert_true("Hermes Agent: enabled" in show.stdout, "config show must include Hermes Agent status")

        openai_config = config
        openai_config["local_llm"]["enabled"] = True
        openai_config["local_llm"]["command_generation_enabled"] = True
        openai_config["local_llm"]["provider"] = "openai_compatible"
        openai_config["local_llm"]["base_url"] = "https://example.test/v1"
        openai_config["local_llm"]["endpoint"] = ""
        openai_config["local_llm"]["model"] = "custom-model"
        openai_config["local_llm"]["api_key_env"] = "OPENAI_API_KEY"
        config_path.write_text(json.dumps(openai_config), encoding="utf-8")
        dotenv_path.write_text(dotenv.replace("OPENAI_API_KEY=sk-new-secret-1234", "OPENAI_API_KEY=sk-compatible"), encoding="utf-8")

        doctor = run_command(["config", "doctor", "--config", str(config_path)])
        assert_true(doctor.returncode == 0, "config doctor failed")
        assert_true(
            "https://example.test/v1/chat/completions" in doctor.stdout,
            "doctor must show normalized OpenAI-compatible chat completions URL",
        )

        openai_config["local_llm"]["base_url"] = "http://localhost:1234/v1"
        openai_config["local_llm"]["api_key_env"] = ""
        config_path.write_text(json.dumps(openai_config), encoding="utf-8")
        local_doctor = run_command(["config", "doctor", "--config", str(config_path)])
        assert_true(local_doctor.returncode == 0, "config doctor failed for no-token local endpoint")
        assert_true(
            "requests are sent without Authorization" in local_doctor.stdout,
            "doctor must allow OpenAI-compatible local endpoints without an API key",
        )

    print("config wizard checks passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as error:
        print(f"config wizard regression: {error}", file=sys.stderr)
        raise SystemExit(1)
