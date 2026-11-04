#!/usr/bin/env python3
"""Behavioral CLI tests; no provider requests or real credentials."""
from __future__ import annotations
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / 'app/.build/debug/fluid-push-to-talk'


class SubscriptionSetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='subscription-setup-', dir=os.environ.get('TMPDIR'))
        self.addCleanup(self.temp.cleanup)
        self.config = Path(self.temp.name) / 'config.json'
        self.dotenv = self.config.with_name('.env')
        self.dotenv.write_text('UNRELATED=keep\nOPENAI_API_KEY=preserve-test-value\n', encoding='utf-8')

    def cli(self, *args, answers=None):
        return subprocess.run([str(BIN), *args, '--config', str(self.config)], input=answers,
                              text=True, capture_output=True, timeout=20, cwd=ROOT)

    def test_fresh_defaults_use_codex_subscription_and_luna(self):
        done = self.cli('config', 'reset', '--yes')
        self.assertEqual(done.returncode, 0, done.stderr)
        config = json.loads(self.config.read_text())
        self.assertEqual(config.get('command_auth'), 'hermes')
        self.assertEqual(config.get('command_model'), 'gpt-6-luna')
        show = self.cli('config', 'show')
        self.assertIn('gpt-6-luna', show.stdout)
        self.assertNotIn('API key OPENAI_API_KEY', show.stdout)

    def test_setup_codex_skips_key_and_preserves_secrets(self):
        # language, shortcut, OpenAI, Hermes auth, model, Hermes shortcut mode, save
        done = self.cli('setup', answers='\n\n1\n1\n\n2\ny\n')
        self.assertEqual(done.returncode, 0, done.stderr)
        config = json.loads(self.config.read_text())
        self.assertEqual(config.get('command_auth'), 'hermes')
        self.assertEqual(config.get('command_model'), 'gpt-6-luna')
        self.assertNotIn('API key for OPENAI_API_KEY', done.stdout)
        self.assertEqual(self.dotenv.read_text(), 'UNRELATED=keep\nOPENAI_API_KEY=preserve-test-value\n')
        self.assertEqual(stat.S_IMODE(self.dotenv.stat().st_mode), 0o600)

    def test_legacy_config_keeps_api_key_mode(self):
        self.config.write_text('{"command_provider":"openai"}')
        done = self.cli('config', 'show')
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn('API key OPENAI_API_KEY', done.stdout)
        self.assertIn('gpt-6-luna', done.stdout)

    def test_haiku_subscription_warns_about_separate_credits(self):
        done = self.cli('setup', answers='\n\n3\n1\n\n2\ny\n')
        self.assertEqual(done.returncode, 0, done.stderr)
        config = json.loads(self.config.read_text())
        self.assertEqual(config.get('command_provider'), 'anthropic')
        self.assertEqual(config.get('command_auth'), 'hermes')
        self.assertEqual(config.get('command_model'), 'claude-haiku-5-5')
        self.assertIn('extra usage credits', done.stdout)
        self.assertNotIn('API key for ANTHROPIC_API_KEY', done.stdout)

    def test_api_mode_custom_model_and_key_are_preserved(self):
        done = self.cli('setup', answers='\n\n1\n2\ngpt-6.1-sol\nnew-test-key\n2\ny\n')
        self.assertEqual(done.returncode, 0, done.stderr)
        config = json.loads(self.config.read_text())
        self.assertEqual(config.get('command_auth'), 'api_key')
        self.assertEqual(config.get('command_model'), 'gpt-6.1-sol')
        self.assertIn('OPENAI_API_KEY=new-test-key', self.dotenv.read_text())
        self.assertIn('UNRELATED=keep', self.dotenv.read_text())
        self.assertNotIn('new-test-key', done.stdout + done.stderr)

    def test_invalid_provider_auth_pair_is_rejected(self):
        self.config.write_text('{"command_provider":"cerebras","command_auth":"hermes"}')
        done = self.cli('config', 'show')
        self.assertNotEqual(done.returncode, 0)

    def test_invalid_model_is_not_saved(self):
        done = self.cli('setup', answers='\n\n1\n1\ninvalid model with spaces\n')
        self.assertNotEqual(done.returncode, 0)
        self.assertFalse(self.config.exists())


if __name__ == '__main__':
    unittest.main()
