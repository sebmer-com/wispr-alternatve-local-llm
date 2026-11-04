#!/usr/bin/env python3
"""Compile and exercise production Swift 6 clients without XCTest/Xcode or credentials."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRATCH = Path.home() / ".hermes/cache/scratch"


class SubscriptionClientCase(unittest.TestCase):
    def test_real_swift_clients(self):
        SCRATCH.mkdir(parents=True, exist_ok=True)
        env = dict(os.environ, TMPDIR=str(SCRATCH))
        with tempfile.TemporaryDirectory(prefix="subscription-clients-", dir=SCRATCH) as tmp:
            executable = Path(tmp) / "clients"
            sources = [
                ROOT / "app/Sources/OpenAI/CommandLLMClient.swift",
                ROOT / "app/Sources/Command/CommandRequestDiagnostics.swift",
                ROOT / "app/Sources/OpenAI/OpenAIResponsesClient.swift",
            ]
            for relative in ("Command/HermesCommandClient.swift", "Anthropic/AnthropicMessagesClient.swift"):
                source = ROOT / "app/Sources" / relative
                if source.exists():
                    sources.append(source)
            sources.append(ROOT / "tests/fixtures/SubscriptionClientHarness.swift")
            build = subprocess.run(["swiftc", "-swift-version", "6", "-warnings-as-errors", "-parse-as-library", *map(str, sources), "-o", str(executable)], capture_output=True, text=True, env=env, timeout=120)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(executable), tmp], capture_output=True, text=True, env=env, timeout=45)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS", result.stdout)
            print(result.stdout.strip())


if __name__ == "__main__":
    unittest.main()
