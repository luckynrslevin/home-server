---
name: Memory location preference
description: User wants project memory stored in the repo itself, not in ~/.claude
type: feedback
---

Store project memory files in the repo at `.claude/memory/`, not in the default `~/.claude/projects/` path.

**Why:** User wants memory to be part of the repo so it's versioned and portable.

**How to apply:** Always read/write memory from the repo's `.claude/memory/` directory.
