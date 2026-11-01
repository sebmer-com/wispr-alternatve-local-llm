#!/usr/bin/env python3
"""Offline bridge contract tests. Run: python3 tests/hermes_bridge_case.py -v."""
import base64
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from types import ModuleType, SimpleNamespace
from unittest.mock import Mock, patch
import zlib

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / "scripts" / "hermes_command_bridge.py"


def load_bridge():
    spec = importlib.util.spec_from_file_location("hermes_command_bridge", BRIDGE)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def request(**changes):
    data = dict(action="complete", provider="openai-codex", model="gpt-6-luna",
                system_prompt="Only the answer.", user_prompt="Instruction",
                images=[], timeout_seconds=60, reasoning_effort="low")
    data.update(changes)
    return data


class FakeRuntime:
    def __init__(self):
        self.calls = []

    def complete(self, data, messages):
        self.calls.append((data, messages))
        return SimpleNamespace(choices=[SimpleNamespace(
            finish_reason="stop", message=SimpleNamespace(content="Answer", tool_calls=None))])


class BridgeCase(unittest.TestCase):
    def test_complete_zero_images_exact_route(self):
        self.assertTrue(BRIDGE.is_file(), "model-only bridge has not been implemented")
        bridge = load_bridge()
        runtime = FakeRuntime()
        self.assertEqual(bridge.handle_request(request(), runtime), {"ok": True, "text": "Answer"})
        data, messages = runtime.calls[0]
        self.assertEqual((data["provider"], data["model"]), ("openai-codex", "gpt-6-luna"))
        self.assertEqual(messages, [{"role": "system", "content": "Only the answer."},
                                    {"role": "user", "content": [{"type": "text", "text": "Instruction"}]}])


class ValidationCase(unittest.TestCase):
    def test_explicit_same_provider_models_are_not_replaced_by_defaults(self):
        bridge = load_bridge()
        for provider, model in [('openai-codex', 'gpt-6.1-sol'), ('anthropic', 'claude-sonnet-5-5')]:
            runtime = FakeRuntime()
            result = bridge.handle_request(request(provider=provider, model=model), runtime)
            self.assertEqual(result['text'], 'Answer')
            self.assertEqual(runtime.calls[0][0]['model'], model)

    def test_invalid_requests_never_reach_runtime(self):
        bridge = load_bridge()
        invalid = [None, [], {}, request(provider="auto"), request(provider="openrouter"),
                   request(provider="anthropic"), request(model="claude-haiku-5-5"),
                   request(model=" gpt-6-luna"), request(action="agent"),
                   request(system_prompt=1), request(user_prompt=None),
                   request(images="path"), request(images=["/a"] * 6),
                   request(timeout_seconds=0), request(timeout_seconds=True),
                   request(timeout_seconds=601), request(timeout_seconds=float("nan")),
                   request(reasoning_effort="high"), request(api_key="SECRET")]
        for data in invalid:
            with self.subTest(data=data):
                runtime = FakeRuntime()
                with self.assertRaises(ValueError):
                    bridge.handle_request(data, runtime)
                self.assertEqual(runtime.calls, [])


def png(pixel):
    def chunk(kind, value):
        return struct.pack(">I", len(value)) + kind + value + struct.pack(">I", zlib.crc32(kind + value))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"\0" + bytes([pixel, 0, 0]))) + chunk(b"IEND", b""))


class ImageCase(unittest.TestCase):
    def test_five_png_images_are_ordered_and_low_detail(self):
        bridge = load_bridge()
        with tempfile.TemporaryDirectory() as folder:
            paths = []
            for i in range(5):
                path = Path(folder) / (str(i) + ".png")
                path.write_bytes(png(i))
                paths.append(str(path))
            runtime = FakeRuntime()
            bridge.handle_request(request(images=paths), runtime)
            content = runtime.calls[0][1][1]["content"]
            self.assertEqual(len(content), 6)
            for i, part in enumerate(content[1:]):
                self.assertEqual(part["type"], "image_url")
                self.assertEqual(part["image_url"]["detail"], "low")
                prefix, encoded = part["image_url"]["url"].split(",", 1)
                self.assertEqual(prefix, "data:image/png;base64")
                self.assertEqual(base64.b64decode(encoded), png(i))

    def test_missing_relative_non_png_and_corrupt_images_fail_closed(self):
        bridge = load_bridge()
        with tempfile.TemporaryDirectory() as folder:
            invalid = Path(folder) / "secret.png"
            for value in (b"private-transcript", b"\xff\xd8\xff", png(1)[:-3], png(1) + b"trailing"):
                invalid.write_bytes(value)
                for path in (str(invalid), "relative.png", str(Path(folder) / "missing.png"), folder, 1):
                    runtime = FakeRuntime()
                    with self.subTest(path=path, size=len(value)):
                        with self.assertRaises(ValueError):
                            bridge.handle_request(request(images=[path]), runtime)
                        self.assertEqual(runtime.calls, [])


class AnswerCase(unittest.TestCase):
    def test_empty_truncated_reasoning_only_and_tool_answers_fail(self):
        bridge = load_bridge()
        for text, reason, tools in [("", "stop", None), ("  ", "stop", None),
                                     ("partial", "length", None), ("partial", "incomplete", None),
                                     ("blocked", "content_filter", None), (None, "stop", None),
                                     ([{"type": "reasoning", "text": "hidden"}], "stop", None),
                                     ("tool", "tool_calls", [object()]), ("text", None, None)]:
            runtime = FakeRuntime()
            runtime.complete = lambda data, messages: SimpleNamespace(choices=[SimpleNamespace(
                finish_reason=reason, message=SimpleNamespace(content=text, tool_calls=tools))])
            with self.subTest(reason=reason, text=text):
                with self.assertRaises(ValueError):
                    bridge.handle_request(request(), runtime)


@contextlib.contextmanager
def hermes_api(provider="openai-codex"):
    """Only the network/auth boundary is faked; bridge implementation is exercised."""
    events = []
    mode = "codex_responses" if provider == "openai-codex" else "anthropic_messages"
    url = "https://chatgpt.com/backend-api/codex" if provider == "openai-codex" else "https://api.anthropic.com"
    runtime = dict(provider=provider, api_mode=mode, api_key="oauth-REFRESHED-SECRET", base_url=url)
    def resolve(**kwargs):
        events.append(("runtime", kwargs))
        return runtime
    response = FakeRuntime().complete({}, [])
    client = SimpleNamespace(api_key=runtime["api_key"], base_url=url,
                             _real_client=SimpleNamespace(timeout=None, max_retries=2),
                             chat=SimpleNamespace(completions=SimpleNamespace(
                                 _model="gpt-6-luna", create=Mock(return_value=response))),
                             close=Mock())
    def factory(selected, **kwargs):
        events.append(("client", selected, kwargs))
        return client, kwargs["model"]
    def codex_factory(**kwargs):
        events.append(("client", "openai-codex", kwargs))
        return client._real_client
    mods = {}
    for name, attributes in {
        "hermes_cli": {}, "agent": {},
        "hermes_cli.runtime_provider": {"resolve_runtime_provider": Mock(side_effect=resolve)},
        "agent.auxiliary_client": {"resolve_provider_client": Mock(side_effect=factory),
                                   "_create_openai_client": Mock(side_effect=codex_factory),
                                   "CodexAuxiliaryClient": Mock(return_value=client)},
        "agent.codex_headers": {"codex_cloudflare_headers": Mock(return_value={"originator": "hermes-agent"})},
        "agent.anthropic_credentials": {"_is_oauth_token": lambda token: token.startswith("oauth-")},
        "agent.anthropic_adapter": {
            "build_anthropic_kwargs": Mock(side_effect=lambda **kw: kw),
            "create_anthropic_message": Mock(return_value=SimpleNamespace(
                stop_reason="end_turn", content=[SimpleNamespace(type="text", text="Answer")]))},
        "agent.transports": {"get_transport": Mock(return_value=SimpleNamespace(
            normalize_response=Mock(return_value=SimpleNamespace(
                content="Answer", tool_calls=None, finish_reason="stop"))))},
    }.items():
        module = ModuleType(name)
        module.__dict__.update(attributes)
        mods[name] = module
    with patch.dict(sys.modules, mods):
        yield SimpleNamespace(events=events, runtime=runtime, client=client, modules=mods)


class RuntimeCase(unittest.TestCase):
    def test_authenticated_runtime_refresh_precedes_explicit_provider_client(self):
        bridge = load_bridge()
        self.assertTrue(hasattr(bridge, "HermesRuntime"), "Hermes runtime integration missing")
        for provider, model in (("openai-codex", "gpt-6-luna"), ("anthropic", "claude-haiku-5-5")):
            with self.subTest(provider=provider), hermes_api(provider) as api:
                result = bridge.handle_request(request(provider=provider, model=model), bridge.HermesRuntime())
                self.assertEqual(result, {"ok": True, "text": "Answer"})
                self.assertEqual(api.events[0], ("runtime", dict(requested=provider, target_model=model)))
                self.assertEqual(api.events[1][0:2], ("client", provider))
                if provider == "openai-codex":
                    self.assertEqual(api.events[1][2]["api_key"], api.runtime["api_key"])
                    self.assertEqual(api.events[1][2]["base_url"], api.runtime["base_url"])
                    self.assertEqual(api.events[1][2]["default_headers"], {"originator": "hermes-agent"})
                    api.modules["agent.auxiliary_client"].CodexAuxiliaryClient.assert_called_once_with(
                        api.client._real_client, model)
                    api.modules["agent.auxiliary_client"].resolve_provider_client.assert_not_called()
                else:
                    self.assertEqual(api.events[1][2]["model"], model)
                    self.assertEqual(api.events[1][2]["api_mode"], api.runtime["api_mode"])
                call = (api.client.chat.completions.create.call_args.kwargs if provider == "openai-codex"
                        else api.modules["agent.anthropic_adapter"].build_anthropic_kwargs.call_args.kwargs)
                self.assertEqual(call["model"], model)
                self.assertIsNone(call.get("tools"))
                self.assertEqual(api.client._real_client.max_retries, 0)
                self.assertEqual(api.client._real_client.timeout, 60)
                if provider == "openai-codex":
                    self.assertEqual(call["timeout"], 60)
                    self.assertEqual(call["reasoning_effort"], "low")
                else:
                    self.assertEqual(api.events[1][2]["explicit_api_key"], "oauth-REFRESHED-SECRET")
                    api.modules["agent.anthropic_adapter"].create_anthropic_message.assert_called_once_with(
                        api.client._real_client, call)
                    api.client.chat.completions.create.assert_not_called()
                api.client.close.assert_called_once()


    def test_codex_low_reasoning_reaches_hermes_adapter_field(self):
        bridge = load_bridge()
        with hermes_api() as api:
            bridge.handle_request(request(), bridge.HermesRuntime())
            call = api.client.chat.completions.create.call_args.kwargs
            self.assertEqual(call.get("extra_body"), {"reasoning": {"enabled": True, "effort": "low"}})

    def test_anthropic_low_effort_is_not_silently_disabled(self):
        bridge = load_bridge()
        with hermes_api("anthropic") as api:
            bridge.handle_request(request(provider="anthropic", model="claude-haiku-5-5"), bridge.HermesRuntime())
            call = api.modules["agent.anthropic_adapter"].build_anthropic_kwargs.call_args.kwargs
            self.assertEqual(call.get("reasoning_config"), {"enabled": True, "effort": "low"})
            self.assertTrue(call["is_oauth"])
            self.assertEqual(call["base_url"], api.runtime["base_url"])

    def test_missing_login_foreign_routes_and_non_subscription_auth_fail_closed(self):
        bridge = load_bridge()
        for provider, model in (("openai-codex", "gpt-6-luna"), ("anthropic", "claude-haiku-5-5")):
            mutations = [dict(api_key=""), dict(provider="openrouter"), dict(api_mode="codex_app_server"),
                         dict(base_url="https://api.anthropic.com.evil.test"),
                         dict(base_url="http://chatgpt.com/backend-api/codex"),
                         dict(base_url="https://user:SECRET@chatgpt.com/backend-api/codex")]
            if provider == "anthropic":
                mutations.append(dict(api_key="sk-ant-api-SECRET"))
            for changed in mutations:
                with self.subTest(provider=provider, changed=changed), hermes_api(provider) as api:
                    api.runtime.update(changed)
                    with self.assertRaises(ValueError):
                        bridge.handle_request(request(provider=provider, model=model), bridge.HermesRuntime())
                    self.assertEqual(len(api.events), 1)
                    api.client.chat.completions.create.assert_not_called()

    def test_auxiliary_client_cannot_switch_model_credential_or_endpoint(self):
        bridge = load_bridge()
        for provider, model in (("openai-codex", "gpt-6-luna"), ("anthropic", "claude-haiku-5-5")):
            for field, value in (("api_key", "wrong-SECRET"), ("base_url", "https://openrouter.ai/api/v1"),
                                  ("model", "other-model")):
                with self.subTest(provider=provider, field=field), hermes_api(provider) as api:
                    if field == "model" and provider == "openai-codex":
                        api.client.chat.completions._model = value
                    elif field == "model":
                        api.modules["agent.auxiliary_client"].resolve_provider_client.side_effect = None
                        api.modules["agent.auxiliary_client"].resolve_provider_client.return_value = (api.client, value)
                    else:
                        setattr(api.client, field, value)
                    with self.assertRaises(ValueError):
                        bridge.handle_request(request(provider=provider, model=model), bridge.HermesRuntime())
                    api.client.chat.completions.create.assert_not_called()
                    api.client.close.assert_called_once()

    def test_auth_failure_identifies_selected_login_without_raw_error(self):
        bridge = load_bridge()
        with hermes_api("anthropic") as api:
            api.modules["hermes_cli.runtime_provider"].resolve_runtime_provider.side_effect = RuntimeError("SECRET")
            payload, status = bridge.protocol(json.dumps(request(action="doctor", provider="anthropic", model="claude-haiku-5-5")).encode(), bridge.HermesRuntime())
            self.assertEqual(status, 1)
            self.assertIn("authentication", payload["error"].lower())
            self.assertIn("anthropic", payload["error"].lower())
            self.assertNotIn("SECRET", payload["error"])
            api.modules["agent.auxiliary_client"].resolve_provider_client.assert_not_called()

    def test_auth_failure_never_builds_client_or_falls_back(self):
        bridge = load_bridge()
        with hermes_api() as api:
            api.modules["hermes_cli.runtime_provider"].resolve_runtime_provider.side_effect = RuntimeError("SECRET")
            with self.assertRaises(Exception):
                bridge.handle_request(request(), bridge.HermesRuntime())
            api.modules["agent.auxiliary_client"].resolve_provider_client.assert_not_called()


class DoctorCase(unittest.TestCase):
    def test_doctor_uses_raw_live_codex_catalog_not_synthetic_defaults(self):
        bridge = load_bridge()
        for entries, status, success in [([{"slug": "gpt-6-luna"}], 200, True),
                                          ([{"slug": "gpt-5.5"}], 200, False),
                                          ([{"slug": "gpt-6-luna", "visibility": "hidden"}], 200, False),
                                          ([], 200, False), ([], 401, False), ([], 503, False)]:
            with self.subTest(entries=entries, status=status), hermes_api() as api:
                fetch = Mock(return_value=(entries, status))
                with patch.dict(sys.modules, {
                    "agent.model_metadata": SimpleNamespace(fetch_codex_catalog_entries=fetch),
                    "agent.codex_headers": SimpleNamespace(codex_account_headers=Mock(return_value={})),
                    "httpx": SimpleNamespace(get=Mock()),
                }):
                    if success:
                        result = bridge.handle_request(request(action="doctor"), bridge.HermesRuntime())
                        self.assertEqual(set(result), {"ok", "detail"})
                        self.assertTrue(result["ok"])
                        self.assertIn("verified live", result["detail"].lower())
                    else:
                        with self.assertRaises(ValueError):
                            bridge.handle_request(request(action="doctor"), bridge.HermesRuntime())
                    fetch.assert_called_once()
                    api.client.chat.completions.create.assert_not_called()

    def test_anthropic_doctor_checks_requested_model_without_completion(self):
        bridge = load_bridge()
        with hermes_api("anthropic") as api:
            api.client._real_client.models = SimpleNamespace(retrieve=Mock(return_value=SimpleNamespace(id="claude-haiku-5-5-20261001")))
            result = bridge.handle_request(request(action="doctor", provider="anthropic", model="claude-haiku-5-5"), bridge.HermesRuntime())
            self.assertTrue(result["ok"])
            api.client._real_client.models.retrieve.assert_called_once_with("claude-haiku-5-5")
            api.client.chat.completions.create.assert_not_called()
            api.client.close.assert_called_once()


class ProtocolCase(unittest.TestCase):
    def test_malformed_stdin_returns_one_safe_error_and_nonzero(self):
        for raw in (b"", b"{", b"[]", b"{} {}", b"\xff", b'{"action":"complete","action":"doctor"}'):
            result = subprocess.run([sys.executable, str(BRIDGE)], input=raw, capture_output=True)
            with self.subTest(raw=raw):
                self.assertNotEqual(result.returncode, 0, "malformed input must not succeed")
                payload = json.loads(result.stdout)
                self.assertEqual(set(payload), {"ok", "error"})
                self.assertFalse(payload["ok"])
                self.assertEqual(result.stderr, b"")

    def test_invalid_inherited_output_fd_never_leaks_environment_value(self):
        result = subprocess.run([sys.executable, str(BRIDGE)], input=b"{", capture_output=True,
                                env=dict(os.environ, HERMES_BRIDGE_OUTPUT_FD="SECRET-invalid"))
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(b"SECRET", result.stdout + result.stderr)
        self.assertEqual(result.stderr, b"")
        self.assertFalse(json.loads(result.stdout)["ok"])

    def test_upstream_errors_never_expose_secrets_or_transcripts(self):
        bridge = load_bridge()
        self.assertTrue(hasattr(bridge, "protocol"), "safe JSON protocol missing")
        for exception in (RuntimeError("Authorization SECRET transcript"), ValueError("SECRET transcript"),
                          TimeoutError("SECRET transcript")):
            runtime = FakeRuntime()
            runtime.complete = Mock(side_effect=exception)
            payload, status = bridge.protocol(json.dumps(request()).encode(), runtime)
            self.assertFalse(payload["ok"])
            self.assertNotEqual(status, 0)
            self.assertNotIn("SECRET", json.dumps(payload))
            self.assertNotIn("transcript", json.dumps(payload))

    def test_native_and_python_diagnostics_are_discarded(self):
        code = ("import importlib.util, os, sys; "
                "s=importlib.util.spec_from_file_location('bridge', sys.argv[1]); "
                "m=importlib.util.module_from_spec(s); s.loader.exec_module(m); "
                "exec('class Noisy:\\n def complete(self, *args):\\n  print(\"SECRET transcript\"); os.write(2,b\"SECRET\"); raise RuntimeError(\"SECRET\")'); "
                "m.HermesRuntime=Noisy; sys.exit(m.main())")
        result = subprocess.run([sys.executable, "-c", code, str(BRIDGE)],
                                input=json.dumps(request()).encode(), capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(b"SECRET", result.stdout + result.stderr)
        self.assertEqual(result.stderr, b"")
        self.assertFalse(json.loads(result.stdout)["ok"])

    def test_timeout_covers_entire_runtime_not_only_http(self):
        bridge = load_bridge()
        self.assertTrue(hasattr(bridge, "protocol"), "bounded protocol missing")
        import time
        runtime = FakeRuntime()
        runtime.complete = Mock(side_effect=lambda *args: time.sleep(2))
        started = time.monotonic()
        payload, status = bridge.protocol(json.dumps(request(timeout_seconds=0.05)).encode(), runtime)
        self.assertNotEqual(status, 0)
        self.assertFalse(payload["ok"])
        self.assertIn("timed out", payload["error"].lower())
        self.assertLess(time.monotonic() - started, 1)


class LauncherCase(unittest.TestCase):
    def make_install(self, folder, managed):
        root = Path(folder) / "Hermes Source With Spaces"
        (root / "hermes_cli").mkdir(parents=True)
        (root / "agent").mkdir()
        for package in ("hermes_cli", "agent"):
            (root / package / "__init__.py").write_text("")
        (root / "hermes_bootstrap.py").write_text("import os; print('SECRET bootstrap'); os.write(2,b'SECRET bootstrap')\n")
        (root / "hermes_cli" / "runtime_provider.py").write_text(
            "def resolve_runtime_provider(**kw):\n"
            " return dict(provider='openai-codex',api_mode='codex_responses',api_key='oauth-SECRET',base_url='https://chatgpt.com/backend-api/codex')\n")
        (root / "agent" / "auxiliary_client.py").write_text(
            "from types import SimpleNamespace as S\n"
            "import os\n"
            "def _create_openai_client(**kw):\n"
            " return S(api_key=kw['api_key'],base_url=kw['base_url'])\n"
            "def CodexAuxiliaryClient(real, model):\n"
            " def create(**args):\n"
            "  print('SECRET transcript'); os.write(2,b'SECRET native'); return S(choices=[S(finish_reason='stop',message=S(content='Answer '+os.environ.get('HERMES_HOME',''),tool_calls=None))])\n"
            " return S(api_key=real.api_key,base_url=real.base_url,_real_client=real,chat=S(completions=S(_model=model,create=create)),close=lambda:None)\n"
            "def resolve_provider_client(*a, **kw):\n raise AssertionError('Must not reselect credentials')\n")
        (root / "agent" / "codex_headers.py").write_text(
            "def codex_cloudflare_headers(*a, **kw):\n return {}\n")
        if managed:
            launcher = root / ".hermes" / "bin" / "hermes"
            launcher.parent.mkdir(parents=True)
            bootstrap = "import sys,runpy; sys.path.insert(0," + repr(str(root)) + "); import hermes_bootstrap; runpy.run_module('hermes_command_bridge',run_name='__main__',alter_sys=True)"
            launcher.write_text("#!" + sys.executable + "\nimport json,sys\n"
                                "assert sys.argv[1:] == ['--print-runtime-command','--module','hermes_command_bridge']\n"
                                "print(json.dumps([" + repr(sys.executable) + ",'-I','-c'," + repr(bootstrap) + "]))\n")
            launcher.chmod(0o755)
        else:
            venv = root / ".venv" / "bin"
            venv.mkdir(parents=True)
            (venv / "python").symlink_to(sys.executable)
        return root

    def test_managed_discovery_and_regular_venv_bootstrap_preserve_profile(self):
        script = ROOT / "scripts" / "run-hermes-bridge.sh"
        self.assertTrue(script.is_file(), "Hermes bridge launcher is missing")
        for managed in (True, False):
            with self.subTest(managed=managed), tempfile.TemporaryDirectory() as folder:
                root = self.make_install(folder, managed)
                profile = str(Path(folder) / "profiles" / "separate")
                env = dict(os.environ, HOME=folder, HERMES_HOME=profile,
                           HERMES_AGENT_DIR=str(root), PATH="/usr/bin:/bin")
                result = subprocess.run(["/bin/bash", str(script)], input=json.dumps(request()).encode(),
                                        env=env, capture_output=True, timeout=15, cwd=folder)
                self.assertEqual(result.stderr, b"")
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(json.loads(result.stdout), {"ok": True, "text": "Answer " + profile})
                self.assertNotIn(b"SECRET", result.stdout)

    def test_bootstrap_failure_still_returns_one_safe_json_object(self):
        script = ROOT / "scripts" / "run-hermes-bridge.sh"
        for managed in (True, False):
            with self.subTest(managed=managed), tempfile.TemporaryDirectory() as folder:
                root = self.make_install(folder, managed)
                (root / "hermes_bootstrap.py").write_text("raise RuntimeError('SECRET bootstrap')\n")
                result = subprocess.run(["/bin/bash", str(script)], input=b"{}", capture_output=True,
                                        env=dict(os.environ, HOME=folder, HERMES_AGENT_DIR=str(root)), timeout=15)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stderr, b"")
                self.assertFalse(json.loads(result.stdout)["ok"])
                self.assertNotIn(b"SECRET", result.stdout)

    def test_missing_hermes_reports_json_and_rejects_credential_arguments(self):
        script = ROOT / "scripts" / "run-hermes-bridge.sh"
        self.assertTrue(script.is_file(), "Hermes bridge launcher is missing")
        with tempfile.TemporaryDirectory() as folder:
            env = dict(os.environ, HOME=folder, HERMES_HOME=folder,
                       HERMES_AGENT_DIR=str(Path(folder) / "missing"), PATH="/usr/bin:/bin")
            for args in ([], ["--api-key", "SECRET"]):
                result = subprocess.run(["/bin/bash", str(script)] + args, input=b"{}", env=env, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(json.loads(result.stdout)["ok"])
                self.assertNotIn(b"SECRET", result.stdout + result.stderr)
                self.assertEqual(result.stderr, b"")


if __name__ == "__main__":
    unittest.main()
