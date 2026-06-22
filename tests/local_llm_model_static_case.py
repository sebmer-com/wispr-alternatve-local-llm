#!/usr/bin/env python3
import json
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
REQUIRED_MODEL = "gpt-5.4-mini"
REQUIRED_PROVIDER = "openai_compatible"
REQUIRED_BASE_URL = "https://api.openai.com/v1"


def main() -> int:
    config = json.loads((REPO_ROOT / "config" / "config.json").read_text(encoding="utf-8"))
    local_llm = config["local_llm"]
    configured_model = local_llm["model"]
    configured_provider = local_llm.get("provider")
    configured_base_url = local_llm.get("base_url")
    if "api_key" in local_llm:
        print("command LLM secret regression: api_key must not be stored in config JSON", file=sys.stderr)
        return 1
    if local_llm.get("dotenv_file") != ".env":
        print("command LLM secret regression: dotenv_file must point to .env", file=sys.stderr)
        return 1
    if configured_provider != REQUIRED_PROVIDER:
        print(
            f"command LLM provider regression: expected {REQUIRED_PROVIDER}, got {configured_provider}",
            file=sys.stderr,
        )
        return 1
    if configured_model != REQUIRED_MODEL:
        print(
            f"command LLM model regression: expected {REQUIRED_MODEL}, got {configured_model}",
            file=sys.stderr,
        )
        return 1
    if configured_base_url != REQUIRED_BASE_URL:
        print(
            "command LLM endpoint regression: configured base_url does not match OpenAI-compatible default",
            file=sys.stderr,
        )
        return 1
    if local_llm.get("api_key_env") != "OPENAI_API_KEY":
        print("command LLM secret regression: api_key_env must default to OPENAI_API_KEY", file=sys.stderr)
        return 1

    azure_source = (
        REPO_ROOT / "app" / "Sources" / "LocalLLM" / "AzureOpenAICommandLLMClient.swift"
    ).read_text(encoding="utf-8")
    factory_source = (
        REPO_ROOT / "app" / "Sources" / "LocalLLM" / "CommandLLMClient.swift"
    ).read_text(encoding="utf-8")
    app_config_source = (REPO_ROOT / "app" / "Sources" / "Config" / "AppConfig.swift").read_text(
        encoding="utf-8"
    )
    mlx_source = (REPO_ROOT / "app" / "Sources" / "LocalLLM" / "LocalMLXChatSession.swift").read_text(
        encoding="utf-8"
    )
    if (
        "AzureOpenAICommandLLMClient" not in factory_source
        or "case .azureOpenAI, .openAICompatible" not in factory_source
    ):
        print("command LLM provider regression: OpenAI-compatible provider factory branch is missing", file=sys.stderr)
        return 1
    for expected in [
        'request.setValue("Bearer \\(apiKey)"',
        'config.provider == .azureOpenAI',
        'request.setValue(apiKey, forHTTPHeaderField: "api-key")',
    ]:
        if expected not in azure_source:
            print(f"command LLM auth regression: missing {expected}", file=sys.stderr)
            return 1
    for expected in ['maxTokens = "max_tokens"', "ChatCompletionResponse", "session.data(for: request)"]:
        if expected not in azure_source:
            print(f"command LLM chat completions request regression: missing {expected}", file=sys.stderr)
            return 1
    for expected in ["config.maxRetries + 1", "config.requestTimeoutSeconds", "shouldRetry(error)"]:
        if expected not in azure_source:
            print(f"command LLM hosted API retry regression: missing {expected}", file=sys.stderr)
            return 1
    for expected in ["DotEnvFile.loadValue", "resolveDotEnvFiles(relativeTo:"]:
        if expected not in app_config_source:
            print(f"command LLM dotenv regression: missing {expected}", file=sys.stderr)
            return 1
    if 'static let requiredModel = "prism-ml/Ternary-Bonsai-8B-mlx-2bit"' not in mlx_source:
        print("MLX fallback regression: Bonsai requiredModel changed unexpectedly", file=sys.stderr)
        return 1
    if "return model" not in mlx_source:
        print("MLX fallback regression: first-run model download fallback is missing", file=sys.stderr)
        return 1
    for expected in ['"--cache-size"', '"--memory-size"']:
        if expected not in mlx_source:
            print(f"MLX fallback speed regression: missing {expected} llm-tool argument", file=sys.stderr)
            return 1
    if 'Data("/reset\\n".utf8)' not in mlx_source:
        print("MLX fallback speed regression: chat history reset is missing", file=sys.stderr)
        return 1

    command_source = (REPO_ROOT / "app" / "Sources" / "CommandResultGenerator.swift").read_text(
        encoding="utf-8"
    )
    skill_calling_source = (
        REPO_ROOT / "app" / "Sources" / "Skills" / "SkillCallingService.swift"
    ).read_text(encoding="utf-8")
    readiness_source = (
        REPO_ROOT / "app" / "Sources" / "LocalLLM" / "LocalLLMReadinessMonitor.swift"
    ).read_text(encoding="utf-8")
    if 'case commandGenerationEnabled = "command_generation_enabled"' not in app_config_source:
        print("local LLM command toggle regression: config key is missing", file=sys.stderr)
        return 1
    if "var canGenerateCommands: Bool" not in app_config_source:
        print("local LLM command toggle regression: computed command gate is missing", file=sys.stderr)
        return 1
    if "config.localLLM.canGenerateCommands" not in command_source:
        print("local LLM command toggle regression: command generator does not use command gate", file=sys.stderr)
        return 1
    if "config.localLLM.canGenerateCommands" not in readiness_source:
        print("local LLM command toggle regression: readiness monitor does not use command gate", file=sys.stderr)
        return 1
    if "llmClient.requiresWarmUp" not in readiness_source:
        print("command LLM readiness regression: remote providers should not warm a local model", file=sys.stderr)
        return 1
    for expected in ["selectSkillsWithLLM", "Return only a JSON array of exact skill names", "parseSkillNames"]:
        if expected not in skill_calling_source:
            print(f"LLM skill selection regression: missing {expected}", file=sys.stderr)
            return 1
    if "FLUID_OBSIDIAN_DAILY_NOTE" not in skill_calling_source:
        print("tasks skill regression: daily note path is not passed to skill tools", file=sys.stderr)
        return 1

    print("command LLM provider static checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
