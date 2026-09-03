#!/usr/bin/env python3
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES = REPO_ROOT / "app" / "Sources"


def main() -> int:
    config = json.loads((REPO_ROOT / "config" / "config.json").read_text(encoding="utf-8"))
    app_config = (SOURCES / "Config" / "AppConfig.swift").read_text(encoding="utf-8")
    runtime = (SOURCES / "AppRuntime.swift").read_text(encoding="utf-8")
    generator = (SOURCES / "CommandResultGenerator.swift").read_text(encoding="utf-8")
    cerebras_path = SOURCES / "Cerebras" / "CerebrasChatCompletionsClient.swift"
    cerebras = cerebras_path.read_text(encoding="utf-8") if cerebras_path.exists() else ""
    gemini_path = SOURCES / "Gemini" / "GeminiClient.swift"
    gemini = gemini_path.read_text(encoding="utf-8") if gemini_path.exists() else ""
    checks = [
        (config.get("command_provider") == "openai", "default config must select command_provider=openai"),
        ('case commandProvider = "command_provider"' in app_config, "AppConfig must serialize command_provider"),
        ('case openAI = "openai"' in app_config, "command provider must decode openai"),
        ("case cerebras" in app_config, "command provider must decode cerebras"),
        ("case gemini" in app_config, "command provider must decode gemini"),
        ("CerebrasChatCompletionsClient" in runtime, "runtime must construct the Cerebras provider"),
        ("GeminiClient" in runtime, "runtime must construct the Gemini provider"),
        ("config.commandProvider" in runtime, "runtime provider selection must use command_provider"),
        (cerebras_path.exists(), "Cerebras Chat Completions client source must exist"),
        ('model = "gemma-4-31b"' in cerebras, "Cerebras model must be fixed to gemma-4-31b"),
        ("temperature" in cerebras and "0.2" in cerebras, "Cerebras temperature must be 0.2"),
        ("maxTokens" in cerebras and "256" in cerebras, "Cerebras max_tokens must be 256"),
        ('forHTTPHeaderField: "User-Agent"' in cerebras, "Cerebras requests must set User-Agent explicitly"),
        (gemini_path.exists(), "Gemini client source must exist"),
        ('model = "gemini-3.5-flash"' in gemini, "Gemini model must be fixed to gemini-3.5-flash"),
        ("return request.fallback" not in generator, "provider errors must not return a transcript fallback"),
        ("catch" not in generator[generator.find("func generate"):generator.find("private struct CommandRequest")], "generator must propagate provider errors"),
    ]
    failed = False
    for passed, message in checks:
        if not passed:
            print(f"command provider regression: {message}", file=sys.stderr)
            failed = True
    if failed:
        return 1
    print("command provider static checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
