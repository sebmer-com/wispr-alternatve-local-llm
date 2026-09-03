#!/usr/bin/env python3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "app" / "Sources"


def main() -> int:
    diagnostics_path = SOURCES / "Command" / "CommandRequestDiagnostics.swift"
    store_path = SOURCES / "Command" / "FailedCommandTurnStore.swift"
    runtime = (SOURCES / "AppRuntime.swift").read_text(encoding="utf-8")
    diagnostics = diagnostics_path.read_text(encoding="utf-8") if diagnostics_path.exists() else ""
    store = store_path.read_text(encoding="utf-8") if store_path.exists() else ""
    all_clients = "\n".join(
        path.read_text(encoding="utf-8")
        for directory in [SOURCES / "OpenAI", SOURCES / "Cerebras", SOURCES / "Gemini"]
        for path in directory.glob("*.swift")
    )
    networking_source = diagnostics + "\n" + all_clients
    checks = [
        (diagnostics_path.exists(), "shared command request diagnostics source must exist"),
        (store_path.exists(), "failed command turn store source must exist"),
        ("sha256=" in diagnostics, "image SHA-256 must be logged"),
        ("base64_chars=" in diagnostics, "encoded image length must be logged"),
        ("payload_bytes=" in networking_source, "request payload bytes must be logged"),
        ("attempt=" in networking_source, "each network attempt must be logged"),
        ("timeout_seconds=" in networking_source, "configured timeout must be logged"),
        ("retry_reason=" in networking_source, "retry reason must be logged"),
        ("request_id=" in networking_source, "provider request ID must be logged"),
        ("error_domain=" in networking_source and "error_code=" in networking_source, "terminal NSError identity must be logged"),
        ("Authorization" not in diagnostics, "diagnostics helper must never log authorization"),
        ("rawBase64" not in diagnostics, "diagnostics must not log raw Base64 bodies"),
        ("struct FailedCommandTurnManifest" in store, "failed turn JSON manifest contract is missing"),
        ("information" in store and "command" in store and "image" in store.lower(), "manifest must retain transcript, command, and images"),
        ("retainFailedInteraction" in runtime, "provider, Hermes, or delivery errors must retain the failed turn"),
        ("clearFailedCommandTurnAfterSuccess" in runtime, "successful command delivery must clear the retained turn"),
        ("guard outcome == .delivered" in runtime, "retained turn must clear only after confirmed delivery"),
        ("DeliveryPolicy.permission" in runtime, "disabled paste/dump routes must return an explicit skipped outcome"),
    ]
    failed = False
    for passed, message in checks:
        if not passed:
            print(f"command diagnostics regression: {message}", file=sys.stderr)
            failed = True
    if failed:
        return 1
    print("command diagnostics static checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
