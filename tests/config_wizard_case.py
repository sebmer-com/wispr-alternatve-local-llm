#!/usr/bin/env python3
import json
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
BINARY = REPO_ROOT / "app" / ".build" / "debug" / "fluid-push-to-talk"


def require(condition: bool, message: str) -> bool:
    if condition:
        return False
    print(f"config wizard regression: {message}", file=sys.stderr)
    return True


def run(args: list[str], input_text: str | None = None) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        [str(BINARY), *args],
        cwd=REPO_ROOT,
        input=input_text,
        text=True,
        capture_output=True,
        timeout=20,
    )
    if completed.stdout:
        print(completed.stdout, end="")
    if completed.stderr:
        print(completed.stderr, end="", file=sys.stderr)
    return completed


def main() -> int:
    failed = False
    wizard = (REPO_ROOT / "app" / "Sources" / "CLI" / "ConfigWizard.swift").read_text(encoding="utf-8")
    options = (REPO_ROOT / "app" / "Sources" / "CLI" / "Options.swift").read_text(encoding="utf-8")
    config_source = (REPO_ROOT / "app" / "Sources" / "Config" / "AppConfig.swift").read_text(encoding="utf-8")

    for needle, source, message in [
        ("Transcription language", wizard, "onboarding must ask for transcription language"),
        ('label: "Paste Shortcut"', wizard, "onboarding must configure the paste shortcut"),
        ("Choose command provider", wizard, "onboarding must ask for a command provider"),
        ("OpenAI", wizard, "onboarding must offer OpenAI"),
        ("Cerebras", wizard, "onboarding must offer Cerebras"),
        ("Gemini", wizard, "onboarding must offer Gemini"),
        ("full-desktop screenshot", wizard, "onboarding must explain screenshot context"),
        ("Request Screen Recording permission now?", wizard, "onboarding must offer Screen Recording permission"),
        ("every mode continues with text only.", wizard, "onboarding must explain text-only fallback"),
        ("Choose Control + Option mode", wizard, "onboarding must select Markdown Dump or Hermes"),
        ("Edit optional features", wizard, "config menu must separate optional features"),
        ("command provider", wizard.lower(), "optional config must retain provider context"),
        ('chmod(url.path, S_IRUSR | S_IWUSR)', wizard, ".env writer must enforce mode 0600"),
        ("didReplace", wizard, ".env writer must preserve existing entries"),
        ("if configExists {", wizard, "existing setup must use a preservation branch"),
        ("config.asr.language = AsrLanguageResolver.normalizePreference", wizard, "existing setup may normalize only schema-safe language state"),
        ("} else {\n            normalizeInstallLocalDefaults(&config)", wizard, "install-only defaults must apply only to new configs"),
        ('case commandProvider = "command_provider"', config_source, "command_provider config key is missing"),
        ('case controlOptionMode = "control_option_mode"', config_source, "control_option_mode config key is missing"),
        ("gpt-5.6-luna", options, "CLI help must explain the OpenAI model"),
        ("gemma-4-31b", options, "CLI help must explain the Cerebras model"),
        ("gemini-3.5-flash", options, "CLI help must explain the Gemini model"),
    ]:
        failed |= require(needle in source, message)

    for forbidden in ["Simple Setup (recommended)", "Advanced Setup", "OpenAI-compatible API preset", "Local MLX"]:
        failed |= require(forbidden not in wizard, f"obsolete onboarding choice remains: {forbidden}")

    with tempfile.TemporaryDirectory() as temp_dir:
        config_path = Path(temp_dir) / "config.json"
        dotenv_path = Path(temp_dir) / ".env"
        config_path.write_text('{"local_llm":{"provider":"mlx"},"skills":{"directory":"old"}}', encoding="utf-8")
        dotenv_path.write_text("OPENAI_API_KEY=remove-me\nOTHER_SECRET=remove-me-too\n", encoding="utf-8")
        reset = run(["config", "reset", "--yes", "--config", str(config_path)])
        failed |= require(reset.returncode == 0, "config reset failed")
        reset_config = json.loads(config_path.read_text(encoding="utf-8"))
        failed |= require("local_llm" not in reset_config, "config reset must remove local_llm")
        failed |= require("skills" not in reset_config, "config reset must remove skills")
        failed |= require(reset_config.get("asr", {}).get("language") == "system", "config reset must default language to system")
        failed |= require(reset_config.get("control_option_mode") == "dump", "config reset must default Control + Option to dump")
        failed |= require("enabled" not in reset_config.get("hermes_agent", {}), "config reset must not write legacy hermes_agent.enabled")
        failed |= require(reset_config.get("hotkeys", {}).get("bluetooth", {}).get("enabled") is False, "config reset must disable Bluetooth")
        failed |= require("OPENAI_API_KEY" not in dotenv_path.read_text(encoding="utf-8"), "config reset must clear secrets")
        failed |= require(stat.S_IMODE(dotenv_path.stat().st_mode) == 0o600, ".env must use mode 0600")

    with tempfile.TemporaryDirectory() as temp_dir:
        config_path = Path(temp_dir) / "config.json"
        dotenv_path = Path(temp_dir) / ".env"
        existing = json.loads((REPO_ROOT / "config" / "config.json").read_text(encoding="utf-8"))
        existing["asr"]["model_version"] = "v2"
        existing["audio_input"] = {"device_uid": "custom-uid", "device_name": "Custom Mic"}
        existing["dump"]["markdown_file"] = "~/Custom/Daily/YYYY-MM-DD.md"
        existing["hermes_agent"]["workdir"] = "~/CustomHermes"
        existing["bluetooth_keyboard"] = {"port": "/dev/cu.custom", "chunk_size": 64}
        existing["local_llm"] = {"provider": "mlx"}
        existing["skills"] = {"directory": "old"}
        config_path.write_text(json.dumps(existing), encoding="utf-8")
        dotenv_path.write_text("OTHER_SECRET=keep-me\nOPENAI_API_KEY=old-key\nCEREBRAS_API_KEY=keep-cerebras\n", encoding="utf-8")

        setup = run(
            ["setup", "--config", str(config_path)],
            input_text="\n\n1\nsk-new-secret-1234\n1\n\ny\n",
        )
        failed |= require(setup.returncode == 0, "piped core setup failed")
        saved = json.loads(config_path.read_text(encoding="utf-8"))
        failed |= require(saved["asr"]["model_version"] == "v2", "core setup must preserve the ASR model version")
        failed |= require(saved["audio_input"] == existing["audio_input"], "core setup must preserve the selected microphone")
        failed |= require(saved["dump"]["markdown_file"] == existing["dump"]["markdown_file"], "core setup must preserve the dump path")
        failed |= require(saved["hermes_agent"]["workdir"] == existing["hermes_agent"]["workdir"], "core setup must preserve the Hermes workdir")
        failed |= require(saved["bluetooth_keyboard"] == existing["bluetooth_keyboard"], "core setup must preserve Bluetooth settings")
        failed |= require(saved["control_option_mode"] == "dump", "core setup must save the selected Control + Option mode")
        failed |= require("enabled" not in saved["hermes_agent"], "core setup must remove legacy hermes_agent.enabled")
        failed |= require("local_llm" not in saved and "skills" not in saved, "core setup must remove legacy fields")
        dotenv = dotenv_path.read_text(encoding="utf-8")
        failed |= require("OTHER_SECRET=keep-me" in dotenv, "core setup must preserve unrelated secrets")
        failed |= require("OPENAI_API_KEY=sk-new-secret-1234" in dotenv, "core setup must update the OpenAI key")
        failed |= require("CEREBRAS_API_KEY=keep-cerebras" in dotenv, "core setup must preserve the Cerebras key")
        failed |= require(stat.S_IMODE(dotenv_path.stat().st_mode) == 0o600, "core setup must enforce .env mode 0600")

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
