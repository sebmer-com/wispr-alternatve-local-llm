#!/usr/bin/env python3
import os
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
INSTALL = REPO_ROOT / "install.sh"
GITHUB_INSTALL = REPO_ROOT / "github-install.sh"
README = REPO_ROOT / "README.md"


def require(condition: bool, message: str) -> bool:
    if condition:
        return False
    print(f"installer regression: {message}", file=sys.stderr)
    return True


def main() -> int:
    failed = False
    install = INSTALL.read_text(encoding="utf-8")
    github_install = GITHUB_INSTALL.read_text(encoding="utf-8")
    readme = README.read_text(encoding="utf-8")

    failed |= require(os.access(INSTALL, os.X_OK), "install.sh must be executable")
    failed |= require(os.access(GITHUB_INSTALL, os.X_OK), "github-install.sh must be executable")

    for needle, message in [
        ("--reset-state", "install.sh must support state reset"),
        ("--setup", "install.sh must support direct onboarding"),
        ("--no-launch", "install.sh must support no-launch installs"),
        ("--preserve-state", "install.sh must support preserving existing state"),
        ("config reset --yes", "install.sh must hard reset through the CLI command"),
        ('ln -sf "${APP_BIN}" "${BIN_DIR}/fluid-push-to-talk"', "install.sh must install a ~/.local/bin symlink"),
        ('"${APP_BIN}" config doctor || true', "install.sh must run doctor after setup"),
    ]:
        failed |= require(needle in install, message)

    for needle, message in [
        ('DEFAULT_GITHUB_REPO="sebmer-com/wispr-alternatve-local-llm"', "github installer must default to the public repo"),
        ('SOURCE_DIR="${LOCAL_AUDIO_SOURCE_DIR:-$HOME/.local/share/fluid-push-to-talk/source}"', "github installer must use the customer source directory"),
        ("git clone --depth 1", "github installer must clone shallowly"),
        ("git -C \"${SOURCE_DIR}\" fetch --depth 1", "github installer must update existing clones"),
        ("--print-command", "github installer must expose a dry command print path"),
        ('command -v git', "github installer must validate git"),
        ('command -v swift', "github installer must validate swift"),
        ('exec "${INSTALL_CMD[@]}" < /dev/tty', "github installer must reopen terminal stdin for interactive setup"),
        ('LOCAL_AUDIO_INSTALL_STDIN', "github installer must expose a noninteractive stdin override"),
    ]:
        failed |= require(needle in github_install, message)

    one_liner = (
        "curl -fsSL https://raw.githubusercontent.com/sebmer-com/wispr-alternatve-local-llm/main/github-install.sh "
        "| bash -s -- --reset-state --setup"
    )
    failed |= require(one_liner in readme, "README must document the customer one-line installer")

    completed = subprocess.run(
        [str(GITHUB_INSTALL), "--print-command", "--reset-state", "--setup", "--no-launch"],
        cwd=REPO_ROOT,
        text=True,
        capture_output=True,
        timeout=10,
    )
    if completed.stdout:
        print(completed.stdout, end="")
    if completed.stderr:
        print(completed.stderr, end="", file=sys.stderr)
    failed |= require(completed.returncode == 0, "github installer --print-command must succeed")
    failed |= require("--reset-state --setup --no-launch" in completed.stdout, "print command must preserve pass-through args")

    if failed:
        return 1
    print("installer static checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
