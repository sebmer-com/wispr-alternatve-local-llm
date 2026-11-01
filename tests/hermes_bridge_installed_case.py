#!/usr/bin/env python3
"""Optional installed-Hermes wire tests; no credentials and no network are used.

Run this module under the Hermes managed/venv interpreter and bootstrap, with
this tests directory on sys.path. The stdlib-only contract suite is separate.
"""
import contextlib
import json
from pathlib import Path
import socket
import sys
import tempfile
from types import SimpleNamespace as S
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
from hermes_bridge_case import load_bridge, png, request

try:
    from agent import auxiliary_client as aux
    import httpx
    import openai
except ImportError:
    aux = None


def sdk_message_delivery(native, streaming):
    """Only SDK delivery is faked; Hermes still aggregates and normalizes it."""
    messages = S(create=Mock(return_value=native))
    if streaming:
        class Stream:
            def __iter__(self):
                return iter([S(type="message_stop")])
            def get_final_message(self):
                return native
        @contextlib.contextmanager
        def stream(**kwargs):
            yield Stream()
        messages.stream = Mock(side_effect=stream)
    return messages


@unittest.skipIf(aux is None, "Run with the installed Hermes Python/bootstrap")
class InstalledWireCase(unittest.TestCase):
    def setUp(self):
        self.bridge = load_bridge()
        self.network_guard = patch.object(socket.socket, "connect", side_effect=AssertionError("Live network forbidden in wire tests"))
        self.network_guard.start()
        self.addCleanup(self.network_guard.stop)

    def test_codex_connect_reuses_round_robin_selection_and_refreshed_account_identity(self):
        import base64
        import os
        from agent.credential_pool import CredentialPool, PooledCredential

        def token(account):
            payload = {"exp": 4102444800, "https://api.openai.com/auth": {
                "chatgpt_account_id": account, "chatgpt_data_residency": "eu"}}
            encoded = base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip("=")
            return "offline." + encoded + ".signature"

        endpoint = "https://chatgpt.com/backend-api/codex"
        entries = [PooledCredential(provider="openai-codex", id=str(i), label="offline",
                                   auth_type="oauth", priority=i, source="manual",
                                   access_token=token("refreshed-account-" + str(i)), base_url=endpoint)
                   for i in range(2)]
        with patch("agent.credential_pool.get_pool_strategy", return_value="round_robin"):
            pool = CredentialPool("openai-codex", entries)
        selected = []
        def resolve(**kwargs):
            entry = pool.select(model=kwargs["target_model"])
            assert entry is not None
            selected.append(entry)
            return dict(provider="openai-codex", api_mode="codex_responses",
                        api_key=entry.runtime_api_key, base_url=entry.runtime_base_url)

        def forbidden(req):
            self.fail("Client construction must not send any inference or discovery request")

        with tempfile.TemporaryDirectory() as folder, \
             patch.dict(os.environ, {"HERMES_HOME": str(Path(folder) / "selected-profile")}), \
             patch.object(pool, "_persist") as persist, \
             patch.object(pool, "select", wraps=pool.select) as select, \
             patch("hermes_cli.runtime_provider.resolve_runtime_provider", side_effect=resolve), \
             patch.object(aux, "_load_pool_with_credentials", return_value=pool), \
             patch.object(aux, "_codex_base_url_override", return_value=""), \
             patch.object(aux, "_openai_http_client_kwargs", side_effect=lambda *a, **kw: {
                 "http_client": httpx.Client(transport=httpx.MockTransport(forbidden))}):
            profile = os.environ["HERMES_HOME"]
            for i in range(2):
                runtime = self.bridge.HermesRuntime()
                resolved = runtime.authenticate(request())
                client = runtime.connect(request(), resolved)
                try:
                    self.assertIsInstance(client, aux.CodexAuxiliaryClient)
                    self.assertEqual(client.api_key, selected[i].runtime_api_key)
                    self.assertEqual(str(client.base_url).rstrip("/"), endpoint)
                    headers = httpx.Headers({k: v for k, v in client._real_client.default_headers.items()
                                             if isinstance(v, str)})
                    self.assertEqual(headers["ChatGPT-Account-ID"], "refreshed-account-" + str(i))
                    self.assertEqual(headers["x-openai-internal-codex-residency"], "eu")
                    self.assertEqual(headers["originator"], "hermes-agent")
                    self.assertTrue(headers["user-agent"].startswith("HermesAgent/"))
                    self.assertEqual(client.chat.completions._model, request()["model"])
                    self.assertEqual(os.environ["HERMES_HOME"], profile)
                finally:
                    client.close()
            self.assertEqual(select.call_count, 2, "Only authentication may select the pool")
            self.assertEqual(persist.call_count, 2)
            self.assertEqual([entry.request_count for entry in pool.entries()], [1, 1])

    def test_real_codex_adapter_builds_low_effort_store_false_and_ordered_images(self):
        captured = []
        message = {"type": "message", "role": "assistant", "phase": "final_answer", "status": "completed",
                   "id": "msg_offline", "content": [{"type": "output_text", "text": "Answer", "annotations": []}]}
        final = {"id": "resp_offline", "object": "response", "status": "completed", "output": [message],
                 "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}}
        events = [{"type": "response.output_item.done", "output_index": 0, "item": message},
                  {"type": "response.completed", "response": final}]
        def transport(req):
            captured.append(json.loads(req.content))
            self.assertEqual(req.url.host, "chatgpt.com")
            return httpx.Response(200, headers={"content-type": "text/event-stream"},
                                  content="".join("data: " + json.dumps(e) + "\n\n" for e in events))
        real = openai.OpenAI(api_key="offline-test-only", base_url="https://chatgpt.com/backend-api/codex",
                             http_client=httpx.Client(transport=httpx.MockTransport(transport)), max_retries=0)
        runtime = dict(provider="openai-codex", api_mode="codex_responses", api_key="offline-test-only",
                       base_url="https://chatgpt.com/backend-api/codex")
        with tempfile.TemporaryDirectory() as folder:
            images = []
            for i in range(5):
                image = Path(folder) / (str(i) + ".png")
                image.write_bytes(png(i))
                images.append(str(image))
            with patch("hermes_cli.runtime_provider.resolve_runtime_provider", return_value=runtime), \
                 patch.object(aux, "_resolve_codex_credential_and_base", return_value=(runtime["api_key"], runtime["base_url"])), \
                 patch.object(aux, "_create_openai_client", return_value=real), \
                 patch("agent.transports.codex._codex_efforts_for_route", return_value=("low", "medium", "high")):
                result = self.bridge.handle_request(request(images=images), self.bridge.HermesRuntime())
        self.assertEqual(result, {"ok": True, "text": "Answer"})
        self.assertEqual(len(captured), 1)
        wire = captured[0]
        self.assertEqual(wire["model"], "gpt-6-luna")
        self.assertFalse(wire["store"])
        self.assertEqual(wire["reasoning"]["effort"], "low")
        self.assertNotIn("tools", wire)
        blocks = wire["input"][0]["content"]
        self.assertEqual([part["type"] for part in blocks], ["input_text"] + ["input_image"] * 5)
        import base64
        for i, block in enumerate(blocks[1:]):
            self.assertEqual(block["detail"], "low")
            self.assertEqual(base64.b64decode(block["image_url"].split(",", 1)[1]), png(i))

    def test_real_anthropic_adapter_suspended_or_unknown_native_stop_never_delivers_partial_text(self):
        reasons = ("pause_turn", "future_unknown_stop", "max_tokens", "refusal", "tool_use", None)
        for reason, streaming in [(reason, streaming) for reason in reasons for streaming in (False, True)]:
            with self.subTest(reason=reason, streaming=streaming):
                native = S(id="msg_offline", type="message", role="assistant", model="claude-haiku-5-5",
                           content=[S(type="text", text="PRIVATE SUSPENDED ANSWER")], stop_reason=reason,
                           stop_sequence=None, usage=S(input_tokens=1, output_tokens=1))
                # Stub only SDK delivery. Hermes' native conversion/aggregation
                # and transport normalization are real, not normalized mocks.
                messages = sdk_message_delivery(native, streaming)
                close = Mock()
                real = S(messages=messages, timeout=None, max_retries=2, close=close)
                key = "sk-ant-oat01-offline-test"
                client = aux.AnthropicAuxiliaryClient(real, "claude-haiku-5-5", key,
                                                     "https://api.anthropic.com", is_oauth=True)
                runtime = dict(provider="anthropic", api_mode="anthropic_messages", api_key=key,
                               base_url="https://api.anthropic.com")
                with patch("hermes_cli.runtime_provider.resolve_runtime_provider", return_value=runtime), \
                     patch.object(aux, "resolve_provider_client", return_value=(client, "claude-haiku-5-5")):
                    payload, status = self.bridge.protocol(
                        json.dumps(request(provider="anthropic", model="claude-haiku-5-5")).encode(),
                        self.bridge.HermesRuntime())
                self.assertEqual(status, 1)
                self.assertEqual(set(payload), {"ok", "error"})
                self.assertFalse(payload["ok"])
                self.assertNotIn("PRIVATE", json.dumps(payload))
                call = messages.stream if streaming else messages.create
                call.assert_called_once()
                if streaming:
                    messages.create.assert_not_called()
                self.assertEqual(call.call_args.kwargs["output_config"]["effort"], "low")
                close.assert_called_once()

    def test_real_anthropic_native_tools_never_deliver_text_even_with_final_stop(self):
        for block in (S(type="tool_use", id="tool_offline", name="offline", input={}),
                      S(type="server_tool_use", id="tool_offline", name="offline", input={})):
            with self.subTest(block=block.type):
                native = S(content=[S(type="text", text="PRIVATE PARTIAL ANSWER"), block], stop_reason="end_turn")
                real = S(messages=S(create=Mock(return_value=native)), close=Mock())
                key = "sk-ant-oat01-offline-test"
                client = aux.AnthropicAuxiliaryClient(real, "claude-haiku-5-5", key,
                                                     "https://api.anthropic.com", is_oauth=True)
                runtime = dict(provider="anthropic", api_mode="anthropic_messages", api_key=key,
                               base_url="https://api.anthropic.com")
                with patch("hermes_cli.runtime_provider.resolve_runtime_provider", return_value=runtime), \
                     patch.object(aux, "resolve_provider_client", return_value=(client, "claude-haiku-5-5")):
                    payload, status = self.bridge.protocol(
                        json.dumps(request(provider="anthropic", model="claude-haiku-5-5")).encode(),
                        self.bridge.HermesRuntime())
                self.assertEqual(status, 1)
                self.assertFalse(payload["ok"])
                self.assertNotIn("PRIVATE", json.dumps(payload))
                real.messages.create.assert_called_once()
                real.close.assert_called_once()

    def test_real_anthropic_final_stops_deliver_only_text_and_missing_answers_fail(self):
        thinking = S(type="thinking", thinking="PRIVATE THINKING", signature="offline")
        redacted = S(type="redacted_thinking", data="PRIVATE REDACTED THINKING")
        cases = [(reason, [thinking, redacted, S(type="text", text="Final answer")], True)
                 for reason in ("end_turn", "stop_sequence")]
        cases += [("end_turn", blocks, False) for blocks in (
            [], [thinking, redacted], [S(type="text", text="  ")], None)]
        for reason, blocks, success in cases:
            for streaming in (False, True):
                with self.subTest(reason=reason, blocks=blocks, streaming=streaming):
                    native = S(content=blocks, stop_reason=reason)
                    sdk_messages = sdk_message_delivery(native, streaming)
                    real = S(messages=sdk_messages, close=Mock())
                    key = "sk-ant-oat01-offline-test"
                    client = aux.AnthropicAuxiliaryClient(real, "claude-haiku-5-5", key,
                                                         "https://api.anthropic.com", is_oauth=True)
                    runtime = dict(provider="anthropic", api_mode="anthropic_messages", api_key=key,
                                   base_url="https://api.anthropic.com")
                    with patch("hermes_cli.runtime_provider.resolve_runtime_provider", return_value=runtime), \
                         patch.object(aux, "resolve_provider_client", return_value=(client, "claude-haiku-5-5")):
                        payload, status = self.bridge.protocol(
                            json.dumps(request(provider="anthropic", model="claude-haiku-5-5")).encode(),
                            self.bridge.HermesRuntime())
                    if success:
                        self.assertEqual((payload, status), ({"ok": True, "text": "Final answer"}, 0))
                    else:
                        self.assertEqual(status, 1)
                        self.assertEqual(set(payload), {"ok", "error"})
                    self.assertNotIn("PRIVATE", json.dumps(payload))
                    if streaming:
                        sdk_messages.stream.assert_called_once()
                        sdk_messages.create.assert_not_called()
                    else:
                        sdk_messages.create.assert_called_once()
                    real.close.assert_called_once()

    def test_real_anthropic_adapter_preserves_haiku_images_and_low_effort(self):
        captured = []
        def create(real_client, kwargs, **rest):
            captured.append(kwargs)
            return S(id="msg_offline", type="message", role="assistant", model="claude-haiku-5-5",
                     content=[S(type="text", text="Answer")], stop_reason="end_turn", stop_sequence=None,
                     usage=S(input_tokens=1, output_tokens=1))
        # SDK message delivery is stubbed, not Hermes' wire conversion/normalization.
        real = S(timeout=None, max_retries=2, close=lambda: None)
        client = aux.AnthropicAuxiliaryClient(real, "claude-haiku-5-5", "sk-ant-oat-offline", "https://api.anthropic.com", is_oauth=True)
        runtime = dict(provider="anthropic", api_mode="anthropic_messages", api_key="sk-ant-oat-offline", base_url="https://api.anthropic.com")
        with tempfile.TemporaryDirectory() as folder:
            image = Path(folder) / "image.png"
            image.write_bytes(png(1))
            with patch("hermes_cli.runtime_provider.resolve_runtime_provider", return_value=runtime), \
                 patch.object(aux, "resolve_provider_client", return_value=(client, "claude-haiku-5-5")), \
                 patch("agent.anthropic_adapter.create_anthropic_message", side_effect=create):
                result = self.bridge.handle_request(request(provider="anthropic", model="claude-haiku-5-5", images=[str(image)]), self.bridge.HermesRuntime())
        self.assertEqual(result, {"ok": True, "text": "Answer"})
        wire = captured[0]
        self.assertEqual(wire["model"], "claude-haiku-5-5")
        self.assertEqual(wire["output_config"]["effort"], "low")
        self.assertNotIn("tools", wire)
        self.assertEqual(wire["messages"][0]["content"][1]["source"]["media_type"], "image/png")


if __name__ == "__main__":
    unittest.main()
