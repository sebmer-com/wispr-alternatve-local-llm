#!/usr/bin/env python3
"""One-shot, model-only Hermes subscription bridge (no agent or tool execution)."""


import base64
import json
import logging
import math
import os
from pathlib import Path
import signal
import stat
import struct
import sys
from typing import Any
from urllib.parse import urlsplit
import zlib


class BridgeError(ValueError):
    """Only bridge-authored, non-sensitive messages may cross the process boundary."""


ROUTES = {"openai-codex": "gpt-6-luna", "anthropic": "claude-haiku-5-5"}
FIELDS = {"action", "provider", "model", "system_prompt", "user_prompt", "images",
          "timeout_seconds", "reasoning_effort"}


def validate_request(data):
    if not isinstance(data, dict) or set(data) - FIELDS:
        raise BridgeError("Invalid bridge request.")
    if data.get("action") not in ("complete", "doctor"):
        raise BridgeError("Unsupported bridge action.")
    provider = data.get("provider")
    model = data.get("model")
    import re
    prefix = {"openai-codex": "gpt-", "anthropic": "claude-"}.get(provider) if isinstance(provider, str) else None
    if (not prefix or not isinstance(model, str) or not model.startswith(prefix)
            or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}", model)):
        raise BridgeError("Unsupported provider/model combination.")
    for field in ("system_prompt", "user_prompt"):
        if not isinstance(data.get(field), str):
            raise BridgeError("Prompts must be strings.")
    images = data.get("images")
    if not isinstance(images, list) or len(images) > 5:
        raise BridgeError("Images must contain zero to five absolute PNG paths.")
    timeout = data.get("timeout_seconds")
    if (isinstance(timeout, bool) or not isinstance(timeout, (int, float))
            or not math.isfinite(timeout) or not 0 < timeout <= 600):
        raise BridgeError("Timeout must be greater than zero and at most 600 seconds.")
    if data.get("reasoning_effort") != "low":
        raise BridgeError("Only low reasoning effort is supported.")


def png_content(path):
    error = "Image must be a readable, valid PNG file (maximum 20 MiB)."
    if not isinstance(path, str) or not Path(path).is_absolute() or Path(path).suffix.lower() != ".png":
        raise BridgeError(error)
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as image:
            if not stat.S_ISREG(os.fstat(image.fileno()).st_mode):
                raise BridgeError(error)
            raw = image.read(20 * 1024 * 1024 + 1)
        if len(raw) > 20 * 1024 * 1024 or raw[:8] != b"\x89PNG\r\n\x1a\n":
            raise BridgeError(error)
        offset, seen_header, seen_data, ended = 8, False, False, False
        while offset + 12 <= len(raw):
            length = struct.unpack_from(">I", raw, offset)[0]
            kind = raw[offset + 4:offset + 8]
            end = offset + length + 12
            if end > len(raw):
                raise BridgeError(error)
            body = raw[offset + 8:end - 4]
            if zlib.crc32(kind + body) != struct.unpack_from(">I", raw, end - 4)[0]:
                raise BridgeError(error)
            if not seen_header:
                if kind != b"IHDR" or length != 13 or not all(struct.unpack_from(">II", body)):
                    raise BridgeError(error)
                seen_header = True
            elif kind == b"IHDR":
                raise BridgeError(error)
            if kind == b"IDAT":
                seen_data = True
            if kind == b"IEND":
                ended = length == 0 and end == len(raw)
                break
            offset = end
        if not (seen_header and seen_data and ended):
            raise BridgeError(error)
    except (OSError, ValueError, struct.error):
        raise BridgeError(error) from None
    return {"type": "image_url", "image_url": {
        "url": "data:image/png;base64," + base64.b64encode(raw).decode("ascii"), "detail": "low"}}


class HermesRuntime:
    """Use Hermes' refresh-capable authentication and explicit-provider wire adapters only."""

    def authenticate(self, data):
        from hermes_cli.runtime_provider import resolve_runtime_provider
        provider, model = data["provider"], data["model"]
        # This resolver refreshes expiring OAuth through Hermes, unlike auxiliary
        # Codex singleton reads. Never implement refresh or read auth.json here.
        try:
            runtime = resolve_runtime_provider(requested=provider, target_model=model)
        except ImportError:
            raise
        except Exception:
            raise BridgeError("Selected provider " + provider + " authentication failed or no usable login exists; authenticate its subscription with Hermes. No fallback was used.") from None
        mode = "codex_responses" if provider == "openai-codex" else "anthropic_messages"
        if runtime.get("provider") != provider or runtime.get("api_mode") != mode:
            raise BridgeError("Selected provider did not resolve to its native subscription runtime.")
        key = runtime.get("api_key")
        if not isinstance(key, str) or not key.strip():
            raise BridgeError("Selected provider is not logged in; authenticate with Hermes.")
        url = urlsplit(str(runtime.get("base_url") or ""))
        host, path = (("chatgpt.com", "/backend-api/codex") if provider == "openai-codex"
                      else ("api.anthropic.com", ""))
        if (url.scheme != "https" or url.netloc != host or url.path.rstrip("/") != path
                or url.query or url.fragment):
            raise BridgeError("Selected provider is not using its native subscription endpoint.")
        if provider == "anthropic":
            from agent.anthropic_credentials import _is_oauth_token
            if not _is_oauth_token(key):
                raise BridgeError("Anthropic subscription login is required; API-key billing is not used.")
        return runtime

    def connect(self, data, runtime):
        from agent.auxiliary_client import resolve_provider_client
        provider, model = data["provider"], data["model"]
        # Never call Hermes' auto/aux task fallback dispatchers. Codex's router
        # reselects the pool even with explicit_api_key: construct its native
        # adapter from the already refreshed runtime identity instead.
        if provider == "openai-codex":
            from agent.auxiliary_client import _create_openai_client, CodexAuxiliaryClient
            from agent.codex_headers import codex_cloudflare_headers
            real = _create_openai_client(
                api_key=runtime["api_key"], base_url=runtime["base_url"],
                default_headers=codex_cloudflare_headers(runtime["api_key"], base_url=runtime["base_url"]))
            client = CodexAuxiliaryClient(real, model)
            resolved_model = model
        else:
            client, resolved_model = resolve_provider_client(
                provider, model=model, api_mode=runtime["api_mode"],
                explicit_api_key=runtime["api_key"], explicit_base_url=runtime["base_url"])
        if client is None:
            raise BridgeError("Selected provider client is unavailable; check its Hermes login.")
        try:
            if provider == "openai-codex":
                resolved_model = getattr(client.chat.completions, "_model", None)
            # Refuse changed model/credential/route before dispatch rather than
            # silently using another identity, including after OAuth refresh.
            if (resolved_model != model or getattr(client, "api_key", None) != runtime["api_key"]
                    or str(getattr(client, "base_url", "")).rstrip("/") != runtime["base_url"].rstrip("/")):
                raise BridgeError("Provider client changed the selected model, credential, or route.")
            # Both Hermes adapters retain the real SDK object. Anthropic's adapter
            # doesn't forward per-call timeouts, so configure it at the SDK as well.
            client._real_client.timeout = data["timeout_seconds"]
            client._real_client.max_retries = 0
            return client
        except BaseException:
            client.close()
            raise

    def complete(self, data, messages):
        runtime = self.authenticate(data)
        client = self.connect(data, runtime)
        try:
            kwargs: dict[str, Any] = dict(model=data["model"], messages=messages, max_tokens=4096,
                          timeout=data["timeout_seconds"])
            if data["provider"] == "openai-codex":
                kwargs["reasoning_effort"] = data["reasoning_effort"]
                # Hermes' Codex adapter translates extra_body.reasoning, not the
                # Chat Completions reasoning_effort field, onto Responses wire.
                kwargs["extra_body"] = {"reasoning": {"enabled": True, "effort": data["reasoning_effort"]}}
            else:
                from agent.anthropic_adapter import build_anthropic_kwargs, create_anthropic_message
                from agent.transports import get_transport
                from types import SimpleNamespace
                # The auxiliary shim maps unknown native stop reasons to "stop".
                # Use Hermes' native conversion/SDK aggregation with the SAME
                # authenticated client, but validate before that lossy mapping.
                native_kwargs = build_anthropic_kwargs(
                    model=data["model"], messages=messages, tools=None, max_tokens=4096,
                    reasoning_config={"enabled": True, "effort": data["reasoning_effort"]},
                    is_oauth=True, base_url=runtime["base_url"])
                response = create_anthropic_message(client._real_client, native_kwargs)
                blocks = getattr(response, "content", None)
                if (getattr(response, "stop_reason", None) not in ("end_turn", "stop_sequence")
                        or not isinstance(blocks, list)
                        or any(getattr(block, "type", None) not in ("text", "thinking", "redacted_thinking")
                               for block in blocks)):
                    raise BridgeError("Provider returned an empty, truncated, or non-text answer.")
                normalized = get_transport("anthropic_messages").normalize_response(response, strip_tool_prefix=True)
                return SimpleNamespace(choices=[SimpleNamespace(
                    finish_reason=normalized.finish_reason,
                    message=SimpleNamespace(content=normalized.content, tool_calls=normalized.tool_calls))])
            return client.chat.completions.create(**kwargs)
        finally:
            client.close()

    def doctor(self, data):
        runtime = self.authenticate(data)
        unverified = ("Model availability is unverified; the configured model is a hint only. "
                      "Live model discovery was unavailable; no completion was sent.")
        if data["provider"] == "openai-codex":
            # get_codex_model_ids and even _fetch_models_from_api synthesize
            # forward-compatible models. Only RAW account-scoped rows are evidence.
            from agent.model_metadata import fetch_codex_catalog_entries
            from agent.codex_headers import codex_account_headers
            import httpx
            headers = {"Authorization": "Bearer " + runtime["api_key"],
                       **codex_account_headers(runtime["api_key"])}
            try:
                entries, status = fetch_codex_catalog_entries(
                    lambda url: httpx.get(url, headers=headers, timeout=min(10, data["timeout_seconds"]),
                                         follow_redirects=False), base_url=runtime["base_url"])
            except Exception:
                raise BridgeError(unverified) from None
            if status in (401, 403):
                raise BridgeError("Selected provider rejected model discovery; check its Hermes subscription login.")
            if status != 200 or not entries:
                raise BridgeError(unverified)
            available = any(isinstance(row, dict) and row.get("slug") == data["model"]
                            and row.get("visibility") not in ("hide", "hidden") for row in entries)
            if not available:
                raise BridgeError("Requested model is absent from the verified live account catalog; no fallback was used.")
        else:
            client = self.connect(data, runtime)
            try:
                model = client._real_client.models.retrieve(data["model"])
                if not getattr(model, "id", None):
                    raise BridgeError(unverified)
            except BridgeError:
                raise
            except Exception:
                raise BridgeError(unverified) from None
            finally:
                client.close()
        return {"ok": True, "detail": (
            "Selected provider credentials accepted; verified live model catalog availability for "
            + data["model"] + ". No inference request was made; generation entitlement is not tested.")}


def handle_request(data, runtime):
    validate_request(data)
    if data["action"] == "doctor":
        return runtime.doctor(data)
    content = [{"type": "text", "text": data["user_prompt"]}]
    content.extend(png_content(path) for path in data["images"])
    messages = [{"role": "system", "content": data["system_prompt"]},
                {"role": "user", "content": content}]
    response = runtime.complete(data, messages)
    choices = getattr(response, "choices", None)
    if not choices or len(choices) != 1:
        raise BridgeError("Provider returned no complete answer.")
    choice = choices[0]
    message = getattr(choice, "message", None)
    text = getattr(message, "content", None)
    if (getattr(choice, "finish_reason", None) != "stop" or getattr(message, "tool_calls", None)
            or not isinstance(text, str) or not text.strip()):
        raise BridgeError("Provider returned an empty, truncated, or non-text answer.")
    return {"ok": True, "text": text}


MAX_REQUEST_BYTES = 1024 * 1024


class BridgeTimeout(BaseException):
    """Do not let Hermes SDK retry/error handlers swallow the process deadline."""


def unique_object(pairs):
    data = {}
    for key, value in pairs:
        if key in data:
            raise BridgeError("Invalid JSON request: duplicate fields are not accepted.")
        data[key] = value
    return data


def protocol(raw, runtime):
    previous_handler = None
    previous_timer = None
    try:
        if len(raw) > MAX_REQUEST_BYTES:
            raise BridgeError("Bridge request exceeds the 1 MiB limit.")
        try:
            data = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object)
        except (UnicodeError, ValueError):
            raise BridgeError("Invalid JSON bridge request.") from None
        validate_request(data)
        def expired(signum, frame):
            raise BridgeTimeout()
        previous_handler = signal.signal(signal.SIGALRM, expired)
        previous_timer = signal.setitimer(signal.ITIMER_REAL, data["timeout_seconds"])
        return handle_request(data, runtime), 0
    except BridgeError as exc:
        return {"ok": False, "error": str(exc)}, 1
    except (BridgeTimeout, TimeoutError):
        return {"ok": False, "error": "Hermes model request timed out; no fallback was used."}, 1
    except ImportError:
        return {"ok": False, "error": "Hermes runtime dependencies are unavailable; repair the Hermes installation."}, 1
    except BaseException:
        # Upstream exceptions can embed tokens, prompts and images. Never stringify
        # them, emit tracebacks, or return partial model output.
        return {"ok": False, "error": "Selected Hermes provider request failed; check its login and model availability. No fallback was used."}, 1
    finally:
        if previous_handler is not None:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, previous_handler)
            if previous_timer is not None:
                signal.setitimer(signal.ITIMER_REAL, *previous_timer)


def discover_runtime(bridge_path):
    """Resolve supported managed launch argv, or a regular source .venv install.

    HERMES_AGENT_DIR optionally selects a trusted source installation, not a
    profile. HERMES_HOME is never changed and continues to select credentials.
    No secrets, prompts, or request JSON are supplied as subprocess arguments.
    """
    import shutil
    import subprocess
    explicit = os.environ.get("HERMES_AGENT_DIR")
    roots = [Path(explicit).expanduser()] if explicit else [
        Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes") / "hermes-agent",
        Path.home() / ".hermes" / "hermes-agent"]
    launchers = []
    if not explicit:
        located = shutil.which("hermes")
        if located:
            launchers.append(Path(located))
            installed = Path(located).resolve()
            if installed.parent.name == "bin" and installed.parent.parent.name in (".venv", ".hermes"):
                roots.insert(0, installed.parent.parent.parent)
    for root in roots:
        launchers.extend((root / ".hermes" / "bin" / "hermes", root / ".venv" / "bin" / "hermes"))
    if not explicit:
        launchers.extend((Path.home() / ".local" / "bin" / "hermes", Path.home() / ".hermes" / "bin" / "hermes"))
    for launcher in dict.fromkeys(launchers):
        if not launcher.is_file() or not os.access(str(launcher), os.X_OK):
            continue
        try:
            result = subprocess.run([str(launcher), "--print-runtime-command", "--module", "hermes_command_bridge"],
                                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                    timeout=10, check=False)
            argv = json.loads(result.stdout)
            if (result.returncode == 0 and isinstance(argv, list) and argv
                    and all(isinstance(arg, str) and "\0" not in arg for arg in argv)
                    and Path(argv[0]).is_absolute() and os.access(argv[0], os.X_OK)
                    and len(argv) >= 4 and argv[1:3] == ["-I", "-c"]):
                # Preserve the installation's supported interpreter + bootstrap.
                # Isolated mode ignores PYTHONPATH, so expose ONLY this trusted
                # bridge's directory before bootstrap executes the named module.
                argv[3] = "import sys; sys.path.insert(0," + repr(str(bridge_path.parent)) + "); " + argv[3]
                return argv
        except (OSError, ValueError, subprocess.SubprocessError):
            continue
    for root in dict.fromkeys(roots):
        if not (root / "agent" / "auxiliary_client.py").is_file():
            continue
        for name in ("python", "python3"):
            python = root / ".venv" / "bin" / name
            if python.is_file() and os.access(str(python), os.X_OK):
                # Regular installations may predate hermes_bootstrap. Never guess
                # managed store interpreter/dependency paths or modify Hermes.
                code = ("import os,sys,runpy; os.environ.pop('PYTHONHOME',None); "
                        "os.environ.pop('PYTHONPATH',None); "
                        "sys.path.insert(0," + repr(str(root.resolve())) + "); "
                        "sys._hermes_pin_default_home=True; "
                        + ("import hermes_bootstrap; " if (root / "hermes_bootstrap.py").is_file() else "")
                        + "os.environ.setdefault('HERMES_HOME',os.path.expanduser('~/.hermes')); "
                        + "runpy.run_path(" + repr(str(bridge_path)) + ",run_name='__main__')")
                return [str(python), "-I", "-c", code]
    raise BridgeError("Hermes runtime was not found. Install Hermes, add its launcher to PATH, or set HERMES_AGENT_DIR to its source installation.")


def guard_bootstrap(argv):
    """Keep pre-entry bootstrap failures within the JSON boundary, in one PID."""
    code = argv[3]
    error = json.dumps({"ok": False, "error": "Hermes runtime bootstrap failed; repair the Hermes installation."}) + "\n"
    argv[3] = (
        "import os,sys\ntry:\n exec(" + repr(code) + ")\n"
        "except BaseException:\n"
        " fd=os.environ.pop('HERMES_BRIDGE_OUTPUT_FD',None)\n"
        " if fd is not None:\n  os.write(int(fd)," + repr(error.encode("utf-8")) + ")\n  sys.exit(1)\n"
        " raise\n"
        # A bootstrap that exits normally without executing the bridge is also
        # not success (e.g. incompatible launcher/module implementation).
        "fd=os.environ.pop('HERMES_BRIDGE_OUTPUT_FD',None)\n"
        "if fd is not None:\n os.write(int(fd)," + repr(error.encode("utf-8")) + ")\n sys.exit(1)\n")
    return argv


def main():
    inherited = os.environ.pop("HERMES_BRIDGE_OUTPUT_FD", None)
    try:
        output_fd = int(inherited) if inherited is not None else os.dup(sys.stdout.fileno())
        if output_fd < 3:
            raise ValueError()
        os.fstat(output_fd)
    except (ValueError, OSError):
        output_fd = os.dup(sys.stdout.fileno())
    os.set_inheritable(output_fd, False)
    logging.disable(logging.CRITICAL)
    # Suppress Python, SDK, bootstrap and native diagnostics; the dedicated
    # output descriptor is used exactly once for the final JSON object.
    with open(os.devnull, "w") as null:
        os.dup2(null.fileno(), 1)
        os.dup2(null.fileno(), 2)
    try:
        if sys.argv[1:] == ["--launch"]:
            try:
                argv = guard_bootstrap(discover_runtime(Path(__file__).resolve()))
                os.set_inheritable(output_fd, True)
                os.environ["HERMES_BRIDGE_OUTPUT_FD"] = str(output_fd)
                os.execv(argv[0], argv)
            except BridgeError as exc:
                payload, status = {"ok": False, "error": str(exc)}, 1
            except BaseException:
                payload, status = {"ok": False, "error": "Hermes runtime could not be launched; repair the Hermes installation."}, 1
        elif sys.argv[1:]:
            payload, status = {"ok": False, "error": "Bridge accepts JSON on stdin only."}, 1
        else:
            payload, status = protocol(sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1), HermesRuntime())
        os.write(output_fd, (json.dumps(payload, ensure_ascii=True) + "\n").encode("utf-8"))
        return status
    finally:
        os.close(output_fd)


if __name__ == "__main__":
    sys.exit(main())
