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
    checks = [
        (config.get("command_provider") == "openai", "default config must select command_provider=openai"),
        ('case commandProvider = "command_provider"' in app_config, "AppConfig must serialize command_provider"),
        ('case openAI = "openai"' in app_config, "command provider must decode openai"),
        ("case cerebras" in app_config, "command provider must decode cerebras"),
        ("CerebrasChatCompletionsClient" in runtime, "runtime must construct the Cerebras provider"),
        ("config.commandProvider" in runtime, "runtime provider selection must use command_provider"),
        (cerebras_path.exists(), "Cerebras Chat Completions client source must exist"),
        ('model = "qwen-3.8-27b"' in cerebras, "Cerebras model must be fixed to qwen-3.8-27b"),
        ("temperature" in cerebras and "0.2" in cerebras, "Cerebras temperature must be 0.2"),
        ('maxCompletionTokens = 4_096' in cerebras, "Cerebras must budget for reasoning and answer tokens"),
        ('reasoningEffort = "low"' in cerebras, "Qwen reasoning must be low"),
        ('forHTTPHeaderField: "User-Agent"' in cerebras, "Cerebras requests must set User-Agent explicitly"),
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
