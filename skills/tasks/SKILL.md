---
name: tasks
description: Use when the user asks to add, create, save, append, or record a task, todo, to-do, Aufgabe, Aufgabe hinzufügen, Task, or reminder in Obsidian.
tool: scripts/add_task.py
tool_fallback: true
tool_final_result: true
tool_timeout_seconds: 5
---

Add one task to the configured Obsidian daily note.

Use the Tasks plugin Emoji format:

```markdown
- [ ] #task Description 🔺 ➕ YYYY-MM-DD 📅 YYYY-MM-DD
```

Keep the task description short and action-oriented. The tool writes the task line; after tool output is available, return only a short confirmation.
