#!/usr/bin/env python3
import json
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    config = json.loads((REPO_ROOT / "config" / "config.json").read_text(encoding="utf-8"))
    app_config = (REPO_ROOT / "app" / "Sources" / "Config" / "AppConfig.swift").read_text(encoding="utf-8")
    runtime = (REPO_ROOT / "app" / "Sources" / "AppRuntime.swift").read_text(encoding="utf-8")
    serial = (REPO_ROOT / "app" / "Sources" / "BluetoothKeyboardOutput.swift").read_text(encoding="utf-8")

    checks = [
        (config.get("llm_output") == {
            "paste": "clipboard",
            "dump": "dump",
            "bluetooth": "clipboard",
         }, "Bluetooth output must stay local until the Bluetooth hotkey is explicitly enabled"),
        (config.get("hotkeys", {}).get("bluetooth", {}).get("keys")
         == [],
         "Bluetooth recording must default to disabled"),
        (config.get("hotkeys", {}).get("bluetooth", {}).get("enabled") is False,
         "Bluetooth hotkey must require explicit setup activation"),
        (config.get("bluetooth_keyboard", {}).get("chunk_size") == 32,
         "Bluetooth keyboard must default to the firmware-compatible 32-byte chunks"),
        ('case bluetoothKeyboard = "bluetooth-keyboard"' in app_config,
         "configuration must accept bluetooth-keyboard as an LLM output method"),
        ("options.config.llmOutput.method(for: action)" in runtime,
         "finished command results must be routed through the configured output method"),
        ("text," in runtime and "logAsResult: false" in runtime,
         "plain one-step transcriptions must use the configured output method"),
        ("BluetoothKeyboardOutput(config: options.config.bluetoothKeyboard)" in runtime,
         "runtime must construct the internal Bluetooth keyboard output"),
        ("keyDown" in runtime
         and "handleBluetoothKey" in runtime
         and "handleBluetoothChord(isPressed:" in runtime,
         "hotkey monitor must handle configured Bluetooth key presses and releases"),
        ("guard activeAction != .bluetooth" in runtime,
         "other modifier changes must not stop an active Bluetooth recording"),
        ("static let defaultBluetoothKey = HotkeyKey.rightShift" in (REPO_ROOT / "app" / "Sources" / "Config" / "HotkeysConfig.swift").read_text(encoding="utf-8")
         and "static func parse(_ value: String) -> HotkeyKey?" in (REPO_ROOT / "app" / "Sources" / "Config" / "HotkeysConfig.swift").read_text(encoding="utf-8"),
         "hotkey configuration must support explicit Bluetooth key setup with a right Shift fallback"),
        ("Bluetooth Shortcut-Key" in (REPO_ROOT / "app" / "Sources" / "CLI" / "ConfigWizard.swift").read_text(encoding="utf-8")
         and "Enter fuer Default" in (REPO_ROOT / "app" / "Sources" / "CLI" / "ConfigWizard.swift").read_text(encoding="utf-8"),
         "onboarding must prompt for a Bluetooth key with Enter as the default"),
        ("logOutputConfiguration(options: options)" in runtime
         and "Output-Konfiguration:" in runtime
         and "locationDisplayName" in app_config,
         "startup must identify each configured output as local or Bluetooth"),
        ("Process(" not in serial and "keyboard-cli" not in serial,
         "Bluetooth keyboard output must not launch the external keyboard-cli"),
        ('private static let protocolName = "KBD1"' in serial,
         "serial integration must implement the KBD1 firmware protocol"),
        ("TYPE_CHUNKED" in serial and "crc32" in serial,
         "serial integration must use CRC32 chunked transfer"),
        ("flock(fileDescriptor, LOCK_EX | LOCK_NB)" in serial,
         "serial integration must lock the ESP32 port exclusively"),
        ("B115200" in serial and "tcsetattr" in serial,
         "serial integration must configure the firmware baud rate directly"),
    ]

    failed = False
    for passed, message in checks:
        if not passed:
            print(f"bluetooth keyboard regression: {message}", file=sys.stderr)
            failed = True
    if failed:
        return 1
    print("bluetooth keyboard static checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
