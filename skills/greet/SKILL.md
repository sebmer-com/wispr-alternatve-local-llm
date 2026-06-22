---
name: greet
description: Use only when explicitly asked to run the greet demo skill.
tool: scripts/greet.py
tool_fallback: false
tool_timeout_seconds: 5
---

Use the configured tool to prepare a greeting. If the provided information contains a name, greet that name. If no name is provided, use a generic greeting.
