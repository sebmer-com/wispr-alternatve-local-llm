#!/usr/bin/env python3
"""Opt-in end-to-end subscription smoke. Sends only synthetic text/PNG fixtures."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import time
import zlib

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / 'app/.build/debug/fluid-push-to-talk'


def png(index):
    def chunk(kind, value):
        return struct.pack('>I', len(value)) + kind + value + struct.pack('>I', zlib.crc32(kind + value))
    row = b'\x00' + bytes((index * 40, 100, 180)) * 64
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 64, 64, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(row * 64)) + chunk(b'IEND', b''))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--provider', choices=['openai', 'anthropic'], default='openai')
    args = parser.parse_args()
    model = 'gpt-6-luna' if args.provider == 'openai' else 'claude-haiku-5-5'
    config = json.loads((ROOT / 'config/config.json').read_text())
    config.update(command_provider=args.provider, command_auth='hermes', command_model=model,
                  prompt_config_file=str(ROOT / 'config/promptConfig.json'),
                  text_replacements_file=str(ROOT / 'config/textReplacements.json'))
    # Never selects API-key auth or silently skips a missing subscription.
    with tempfile.TemporaryDirectory(prefix='subscription-live-', dir=os.environ.get('TMPDIR')) as folder:
        config_path = Path(folder) / 'config.json'
        config_path.write_text(json.dumps(config))
        for count, expected in [(0, 'SUBSCRIPTION_OK'), (5, '5')]:
            command = [str(BINARY), '--config', str(config_path), '--test-command-information',
                       'This is a synthetic integration test, not a user recording.', '--test-command',
                       'Reply with exactly SUBSCRIPTION_OK.' if count == 0 else
                       'Count the attached images. Reply with only the number of images, as a single digit.']
            for index in range(count):
                path = Path(folder) / ('fixture-%s.png' % index)
                path.write_bytes(png(index))
                command += ['--test-command-image', str(path)]
            started = time.monotonic()
            done = subprocess.run(command, text=True, capture_output=True, timeout=90, cwd=ROOT)
            # The application diagnostic contains synthetic data only.
            print(done.stdout, end='')
            print(done.stderr, end='')
            results = [line[len('[result] '):].strip() for line in done.stdout.splitlines() if line.startswith('[result] ')]
            if done.returncode != 0 or not results or results[-1].strip('.') != expected:
                raise SystemExit('FAIL %s %s %s-image live smoke (exit %s)' % (args.provider, model, count, done.returncode))
            print('PASS %s %s %s-image live smoke in %.2fs' % (args.provider, model, count, time.monotonic() - started))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
