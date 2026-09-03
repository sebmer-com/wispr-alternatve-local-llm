#!/usr/bin/env python3
import json
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES = REPO_ROOT / "app" / "Sources"


def fail(message: str) -> bool:
    print(f"OpenAI Responses regression: {message}", file=sys.stderr)
    return True


def main() -> int:
    failed = False
    config = json.loads((REPO_ROOT / "config" / "config.json").read_text(encoding="utf-8"))
    prompt_config = json.loads((REPO_ROOT / "config" / "promptConfig.json").read_text(encoding="utf-8"))
    env_example = (REPO_ROOT / ".env.example").read_text(encoding="utf-8")
    all_source = "\n".join(
        path.read_text(encoding="utf-8")
        for path in sorted(SOURCES.rglob("*.swift"))
    )

    failed |= fail("checked-in config must not serialize local_llm") if "local_llm" in config else False
    failed |= fail("checked-in config must not serialize skills") if "skills" in config else False
    core_prompt = prompt_config.get("core_command", {})
    failed |= fail("command prompt must not retain skill-context templates") if "user_template_with_skill_context" in core_prompt else False
    failed |= fail("command prompt must not mention removed skill tools") if "skill" in json.dumps(core_prompt).lower() else False
    failed |= fail(".env.example must document OPENAI_API_KEY") if "OPENAI_API_KEY=" not in env_example else False
    failed |= fail(".env.example must document CEREBRAS_API_KEY") if "CEREBRAS_API_KEY=" not in env_example else False
    failed |= fail(".env.example must document GEMINI_API_KEY") if "GEMINI_API_KEY=" not in env_example else False
    failed |= fail(".env.example must not retain Azure credentials") if "AZURE" in env_example.upper() else False

    required = [
        ("final class OpenAIResponsesClient", "single Responses API client is missing"),
        ('https://api.openai.com/v1/responses', "fixed Responses API endpoint is missing"),
        ('gpt-5.6-luna', "fixed Luna model is missing"),
        ('reasoningEffort = "low"', "low reasoning configuration is missing"),
        ('apiKeyEnvironmentName = "OPENAI_API_KEY"', "OPENAI_API_KEY contract is missing"),
        ('imageDetail = "low"', "low-detail screenshot constant is missing"),
        ('detail: Self.imageDetail', "image requests must use the low-detail constant"),
    ]
    for needle, message in required:
        if needle not in all_source:
            failed |= fail(message)

    if not (SOURCES / "OpenAI" / "OpenAIResponsesClient.swift").is_file():
        failed |= fail("fixed OpenAI client must live under app/Sources/OpenAI")

    forbidden_paths = [
        SOURCES / "Skills",
        REPO_ROOT / "skills",
        SOURCES / "LocalLLM",
    ]
    for path in forbidden_paths:
        if path.exists():
            failed |= fail(f"obsolete provider/skill path remains: {path.relative_to(REPO_ROOT)}")

    forbidden_source = [
        "AzureOpenAICommandLLMClient",
        "LocalMLXChatSession",
        "LocalLLMReadinessMonitor",
        "SkillCallingService",
        "GenericSkillToolRunner",
        "openai_compatible",
    ]
    for needle in forbidden_source:
        if needle in all_source:
            failed |= fail(f"obsolete provider/skill symbol remains: {needle}")

    if failed:
        return 1
    print("OpenAI Responses static checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
